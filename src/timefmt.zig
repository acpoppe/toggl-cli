const std = @import("std");
const Io = std.Io;

/// Current wall-clock time as Unix seconds. In Zig 0.16 the clock is reached
/// through the `Io` instance rather than a free `std.time.timestamp()`.
pub fn nowUnix(io: Io) i64 {
    return Io.Clock.real.now(io).toSeconds();
}

/// Format the current UTC time as an RFC 3339 timestamp (e.g.
/// "2026-05-24T15:04:05Z") into `buf`, returning the written slice.
/// Toggl's API wants the entry `start` in this format.
pub fn nowRfc3339(io: Io, buf: []u8) ![]const u8 {
    return epochToRfc3339(nowUnix(io), buf);
}

/// Convert a Unix timestamp (seconds) to an RFC 3339 UTC string.
pub fn epochToRfc3339(unix_secs: i64, buf: []u8) ![]const u8 {
    // std.time.epoch works on unsigned seconds; negative timestamps (pre-1970)
    // aren't something a time tracker needs, so clamp at 0.
    const secs: u64 = if (unix_secs < 0) 0 else @intCast(unix_secs);

    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch_secs.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_secs.getDaySeconds();

    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1, // day_index is 0-based
        day_secs.getHoursIntoDay(),
        day_secs.getMinutesIntoHour(),
        day_secs.getSecondsIntoMinute(),
    });
}

/// Like epochToRfc3339 but allocates the result.
pub fn epochToRfc3339Alloc(arena: std.mem.Allocator, unix_secs: i64) ![]const u8 {
    var buf: [32]u8 = undefined;
    return arena.dupe(u8, try epochToRfc3339(unix_secs, &buf));
}

/// Parse an RFC 3339 timestamp into Unix seconds (UTC). Handles a trailing
/// `Z` or `±HH:MM` offset and optional fractional seconds. Returns null if the
/// string doesn't look like RFC 3339. Used to do relative time math on an
/// entry's existing start/stop.
pub fn parseRfc3339(s: []const u8) ?i64 {
    if (s.len < 19) return null;
    const y = digits(s, 0, 4) orelse return null;
    const mo = digits(s, 5, 7) orelse return null;
    const d = digits(s, 8, 10) orelse return null;
    const h = digits(s, 11, 13) orelse return null;
    const mi = digits(s, 14, 16) orelse return null;
    const se = digits(s, 17, 19) orelse return null;

    var epoch = civilToDays(y, mo, d) * 86400 + h * 3600 + mi * 60 + se;

    // Skip optional fractional seconds, then read the timezone designator.
    var i: usize = 19;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    }
    if (i < s.len and (s[i] == '+' or s[i] == '-') and i + 6 <= s.len) {
        const oh = digits(s, i + 1, i + 3) orelse 0;
        const om = digits(s, i + 4, i + 6) orelse 0;
        const off = oh * 3600 + om * 60;
        // A "+02:00" wall time is ahead of UTC, so subtract to get UTC.
        epoch -= if (s[i] == '+') off else -off;
    }
    return epoch;
}

/// Unix seconds for a civil UTC date-time.
pub fn civilToEpoch(y: i64, mo: i64, d: i64, h: i64, mi: i64, se: i64) i64 {
    return civilToDays(y, mo, d) * 86400 + h * 3600 + mi * 60 + se;
}

fn digits(s: []const u8, start: usize, end: usize) ?i64 {
    if (end > s.len) return null;
    return std.fmt.parseInt(i64, s[start..end], 10) catch null;
}

/// Days since the Unix epoch for a civil date (proleptic Gregorian).
/// Howard Hinnant's days_from_civil algorithm.
fn civilToDays(y: i64, m: i64, d: i64) i64 {
    const yy = if (m <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400; // [0, 399]
    const mp = @mod(m + 9, 12); // Mar=0 ... Feb=11
    const doy = @divFloor(153 * mp + 2, 5) + d - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

test "epochToRfc3339 formats a known instant" {
    var buf: [32]u8 = undefined;
    // 2021-01-01T00:00:00Z == 1609459200
    const s = try epochToRfc3339(1609459200, &buf);
    try std.testing.expectEqualStrings("2021-01-01T00:00:00Z", s);
}

test "parseRfc3339 round-trips and handles offsets" {
    try std.testing.expectEqual(@as(?i64, 1609459200), parseRfc3339("2021-01-01T00:00:00Z"));
    // Same instant expressed with an offset.
    try std.testing.expectEqual(@as(?i64, 1609459200), parseRfc3339("2021-01-01T02:00:00+02:00"));
    try std.testing.expectEqual(@as(?i64, 1609459200), parseRfc3339("2020-12-31T19:00:00-05:00"));
    // Fractional seconds are ignored.
    try std.testing.expectEqual(@as(?i64, 1609459200), parseRfc3339("2021-01-01T00:00:00.500Z"));
    try std.testing.expect(parseRfc3339("nope") == null);
}
