const std = @import("std");
const Io = std.Io;
const timefmt = @import("timefmt.zig");

/// The system's local timezone, parsed from the IANA tz database. Falls back to
/// UTC if it can't be read. Offsets are looked up per-instant, so DST is
/// handled correctly (an entry in July shows CEST, one in January shows CET).
pub const Zone = struct {
    tz: ?std.Tz = null,

    /// Seconds east of UTC at the given instant.
    pub fn offsetAt(self: Zone, epoch: i64) i32 {
        const tz = self.tz orelse return 0;
        if (tz.transitions.len == 0) {
            return if (tz.timetypes.len > 0) tz.timetypes[0].offset else 0;
        }
        // Transitions are sorted ascending; take the last one at/<= epoch.
        var off = tz.transitions[0].timetype.offset;
        for (tz.transitions) |tr| {
            if (tr.ts <= epoch) off = tr.timetype.offset else break;
        }
        return off;
    }

    /// Abbreviation (e.g. "CET"/"CEST") at the given instant, or "UTC".
    pub fn abbrevAt(self: Zone, epoch: i64) []const u8 {
        const tz = self.tz orelse return "UTC";
        if (tz.transitions.len == 0) return "UTC";
        var tt = tz.transitions[0].timetype;
        for (tz.transitions) |tr| {
            if (tr.ts <= epoch) tt = tr.timetype else break;
        }
        return tt.name();
    }
};

/// Load the system local timezone from /etc/localtime. Best-effort: any
/// failure yields a UTC zone rather than an error. Parsed into `arena`.
pub fn load(arena: std.mem.Allocator, io: Io) Zone {
    var file = Io.Dir.openFileAbsolute(io, "/etc/localtime", .{}) catch return .{};
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);
    const tz = std.Tz.parse(arena, &reader.interface) catch return .{};
    return .{ .tz = tz };
}

/// Format an instant in local time as "YYYY-MM-DD HH:MM ABBR".
pub fn fmtLocal(arena: std.mem.Allocator, zone: Zone, epoch: i64) ![]const u8 {
    const wall = epoch + zone.offsetAt(epoch);
    var buf: [32]u8 = undefined;
    const rfc = try timefmt.epochToRfc3339(wall, &buf); // wall-clock digits, UTC-formatted
    const part = try arena.dupe(u8, rfc[0..16]); // "YYYY-MM-DDTHH:MM"
    part[10] = ' ';
    return std.fmt.allocPrint(arena, "{s} {s}", .{ part, zone.abbrevAt(epoch) });
}
