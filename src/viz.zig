//! Full-screen week calendar (`toggl viz`). Days as columns, hours as rows;
//! each entry is a filled block in its Toggl project color. Paginate weeks with
//! ←/→ or n/p, jump to the current week with `t`, quit with q/Esc. The view
//! fills the terminal and re-renders on resize (a poll loop, since Zig's read
//! auto-retries EINTR so a bare SIGWINCH won't break a blocking read).

const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const builtin = @import("builtin");
const api = @import("api.zig");
const cache = @import("cache.zig");
const color = @import("color.zig");
const timefmt = @import("timefmt.zig");
const localtz = @import("localtz.zig");

const no_project: color.RGB = .{ .r = 60, .g = 60, .b = 66 };
const tick: color.RGB = .{ .r = 52, .g = 52, .b = 60 };

const day_abbr = [7][]const u8{ "MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN" };
const month_abbr = [12][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

const Block = struct {
    day: u8, // 0=Mon .. 6=Sun
    start_min: u16, // minutes from local midnight
    end_min: u16,
    desc: []const u8,
    project: []const u8,
    dur_secs: i64,
    rgb: color.RGB,
    running: bool,
};

/// A controlling terminal in raw mode + alternate screen.
const Term = struct {
    tty: Io.File,
    io: Io,
    fd: posix.fd_t,
    original: posix.termios,

    fn open(io: Io) ?Term {
        var tty = Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch return null;
        if (!(tty.isTty(io) catch false)) {
            tty.close(io);
            return null;
        }
        const fd = tty.handle;
        const original = posix.tcgetattr(fd) catch {
            tty.close(io);
            return null;
        };
        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.iflag.ICRNL = false;
        // VMIN=0 + VTIME=2: read() waits up to ~200ms then returns 0, giving an
        // input timeout without poll() (which busy-loops on /dev/tty on macOS).
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 2;
        posix.tcsetattr(fd, .NOW, raw) catch {
            tty.close(io);
            return null;
        };
        return .{ .tty = tty, .io = io, .fd = fd, .original = original };
    }

    fn close(t: Term) void {
        posix.tcsetattr(t.fd, .NOW, t.original) catch {};
        t.tty.close(t.io);
    }
};

const Size = struct { cols: u16, rows: u16 };

fn winSize(fd: posix.fd_t) Size {
    var ws: posix.winsize = undefined;
    const ok = switch (builtin.os.tag) {
        .linux => std.os.linux.E.init(std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws))) == .SUCCESS,
        else => std.c.ioctl(fd, 0x40087468, &ws) == 0,
    };
    if (!ok or ws.col == 0) return .{ .cols = 120, .rows = 40 };
    return .{ .cols = ws.col, .rows = ws.row };
}

/// Local day number (days since the Unix epoch) for `epoch_utc`.
fn localDay(epoch_utc: i64, zone: localtz.Zone) i64 {
    return @divFloor(epoch_utc + zone.offsetAt(epoch_utc), 86400);
}

/// Monday (local day number) of the week containing `now`.
fn currentMonday(io: Io, zone: localtz.Zone) i64 {
    const today = localDay(timefmt.nowUnix(io), zone);
    // Unix day 0 was a Thursday, so Monday-indexed weekday = (day + 3) mod 7.
    return today - @mod(today + 3, 7);
}

fn dateStr(arena: std.mem.Allocator, daynum: i64) ![]const u8 {
    var buf: [32]u8 = undefined;
    const rfc = try timefmt.epochToRfc3339(daynum * 86400, &buf);
    return arena.dupe(u8, rfc[0..10]);
}

fn fmtDur(buf: []u8, secs_in: i64) []const u8 {
    const secs: u64 = if (secs_in < 0) 0 else @intCast(secs_in);
    return std.fmt.bufPrint(buf, "{d}:{d:0>2}:{d:0>2}", .{ secs / 3600, (secs % 3600) / 60, secs % 60 }) catch buf[0..0];
}

const ProjInfo = struct { label: []const u8, rgb: color.RGB };

/// Resolve a (project, task) pair to a display label and color from the cache.
fn lookup(projects: []const cache.Entry, pid: i64, tid: ?i64) ProjInfo {
    var label: []const u8 = "";
    var hex: []const u8 = "";
    if (tid) |t| {
        for (projects) |e| if (e.project_id == pid and e.task_id != null and e.task_id.? == t) {
            label = e.label;
            hex = e.color;
            break;
        };
    }
    if (label.len == 0) for (projects) |e| if (e.project_id == pid and e.task_id == null) {
        label = e.label;
        hex = e.color;
        break;
    };
    if (label.len == 0) for (projects) |e| if (e.project_id == pid) {
        label = e.label;
        hex = e.color;
        break;
    };
    return .{
        .label = if (label.len > 0) label else "(unknown project)",
        .rgb = color.parseHex(hex) orelse color.hashColor(pid),
    };
}

fn blockFromEntry(e: api.Client.TimeEntry, projects: []const cache.Entry, zone: localtz.Zone, week_mon: i64, now: i64) ?Block {
    const su = if (e.start) |s| (timefmt.parseRfc3339(s) orelse return null) else return null;
    const di = localDay(su, zone) - week_mon;
    if (di < 0 or di > 6) return null;

    const slocal = su + zone.offsetAt(su);
    const smin: u16 = @intCast(@divFloor(@mod(slocal, 86400), 60));
    const running = e.duration < 0;
    const eu = if (running) now else su + e.duration;
    const dur: i64 = if (eu > su) eu - su else 0;
    var emin: i64 = @as(i64, smin) + @divFloor(dur, 60);
    if (emin > 1440) emin = 1440;
    if (emin <= smin) emin = @as(i64, smin) + 1;

    const desc: []const u8 = if (e.description) |d| (if (d.len > 0) d else "(no description)") else "(no description)";
    if (e.project_id) |pid| {
        const info = lookup(projects, pid, e.task_id);
        return .{ .day = @intCast(di), .start_min = smin, .end_min = @intCast(emin), .desc = desc, .project = info.label, .dur_secs = dur, .rgb = info.rgb, .running = running };
    }
    return .{ .day = @intCast(di), .start_min = smin, .end_min = @intCast(emin), .desc = desc, .project = "(no project)", .dur_secs = dur, .rgb = no_project, .running = running };
}

fn fetchWeek(arena: std.mem.Allocator, io: Io, client: ?*api.Client, projects: []const cache.Entry, zone: localtz.Zone, week_mon: i64, cur_mon: i64) ![]const Block {
    if (client) |c| {
        const sd = try dateStr(arena, week_mon - 1);
        const ed = try dateStr(arena, week_mon + 8);
        const entries = try c.list(sd, ed);
        const now = timefmt.nowUnix(io);
        var list: std.ArrayList(Block) = .empty;
        for (entries) |e| {
            if (blockFromEntry(e, projects, zone, week_mon, now)) |b| try list.append(arena, b);
        }
        return list.items;
    }
    // Demo: show the sample week only on the current week.
    if (week_mon == cur_mon) return demoBlocks();
    return &.{};
}

fn padTrunc(w: *Io.Writer, text: []const u8, width: usize) !void {
    var n: usize = 0;
    while (n < width and n < text.len) : (n += 1) try w.writeByte(text[n]);
    while (n < width) : (n += 1) try w.writeByte(' ');
}

fn eol(w: *Io.Writer) !void {
    try w.writeAll("\x1b[K\n"); // clear to end of line + newline
}

fn render(w: *Io.Writer, io: Io, zone: localtz.Zone, week_mon: i64, blocks: []const Block, size: Size) !void {
    try w.writeAll("\x1b[H"); // cursor home

    const cols: usize = size.cols;
    const rows: usize = size.rows;
    const gutter: usize = 7;
    const colw: usize = if (cols > gutter + 7) (cols - gutter) / 7 else 9;
    const inner: usize = if (colw > 1) colw - 1 else colw;
    const today = localDay(timefmt.nowUnix(io), zone);

    var day_tot = [_]i64{0} ** 7;
    var week_tot: i64 = 0;
    for (blocks) |b| {
        day_tot[b.day] += b.dur_secs;
        week_tot += b.dur_secs;
    }

    // ---- header ----
    var mb: [40]u8 = undefined;
    var sb: [40]u8 = undefined;
    const mon_rfc = try timefmt.epochToRfc3339(week_mon * 86400, &mb);
    const sun_rfc = try timefmt.epochToRfc3339((week_mon + 6) * 86400, &sb);
    const mo = std.fmt.parseInt(usize, mon_rfc[5..7], 10) catch 1;
    const d1 = std.fmt.parseInt(usize, mon_rfc[8..10], 10) catch 1;
    const d2 = std.fmt.parseInt(usize, sun_rfc[8..10], 10) catch 1;
    var tb: [32]u8 = undefined;

    try color.on(w, .gray);
    try w.writeAll("‹ p   ");
    try color.off(w);
    try color.on(w, .bold);
    try w.print("{d} – {d} {s} {s}", .{ d1, d2, month_abbr[(mo - 1) % 12], mon_rfc[0..4] });
    try color.off(w);
    try color.on(w, .gray);
    try w.writeAll("   n ›        week total ");
    try color.off(w);
    try color.on(w, .bold);
    try w.print("{s}", .{fmtDur(&tb, week_tot)});
    try color.off(w);
    try eol(w);

    // ---- day headers ----
    var i: usize = 0;
    while (i < gutter) : (i += 1) try w.writeByte(' ');
    for (0..7) |d| {
        const dnum = week_mon + @as(i64, @intCast(d));
        const is_today = dnum == today;
        var db: [40]u8 = undefined;
        const drfc = try timefmt.epochToRfc3339(dnum * 86400, &db);
        const dom = std.fmt.parseInt(usize, drfc[8..10], 10) catch 0;
        var lb: [24]u8 = undefined;
        const lbl = std.fmt.bufPrint(&lb, "{s} {d}", .{ day_abbr[d], dom }) catch "";
        try color.on(w, .bold);
        if (is_today) try color.on(w, .cyan);
        try padTrunc(w, lbl, inner);
        try color.off(w);
        try w.writeByte(' ');
    }
    try eol(w);

    i = 0;
    while (i < gutter) : (i += 1) try w.writeByte(' ');
    for (0..7) |d| {
        try color.on(w, .gray);
        var b2: [32]u8 = undefined;
        try padTrunc(w, fmtDur(&b2, day_tot[d]), inner);
        try color.off(w);
        try w.writeByte(' ');
    }
    try eol(w);

    // ---- choose visible hour window that fills the screen ----
    var min_min: u16 = 24 * 60;
    var max_min: u16 = 0;
    for (blocks) |b| {
        if (b.start_min < min_min) min_min = b.start_min;
        if (b.end_min > max_min) max_min = b.end_min;
    }
    const data_lo: usize = if (max_min == 0) 9 else min_min / 60;
    const data_hi: usize = if (max_min == 0) 17 else (max_min + 59) / 60;

    var vmin: usize = @min(data_lo, 6);
    var vmax: usize = @max(data_hi, 22);
    const avail: usize = if (rows > 5) rows - 4 else (vmax - vmin);
    var range: usize = vmax - vmin;
    var rph: usize = avail / range;
    if (rph < 1) rph = 1;
    if (rph > 3) rph = 3;
    while (range * rph < avail and (vmin > 0 or vmax < 24)) {
        if (vmax < 24) {
            vmax += 1;
            range += 1;
            if (range * rph >= avail) break;
        }
        if (vmin > 0) {
            vmin -= 1;
            range += 1;
        }
    }
    if (range * rph > avail and range > 1) {
        const show = @max(@as(usize, 1), avail / rph);
        vmin = if (data_lo > 0) data_lo - 1 else 0;
        if (vmin + show > 24) vmin = if (24 > show) 24 - show else 0;
        vmax = @min(@as(usize, 24), vmin + show);
        range = vmax - vmin;
    }
    const base: usize = vmin * 60;
    const grid_rows: usize = range * rph;

    // ---- grid ----
    for (0..grid_rows) |gr| {
        const row_start: usize = base + gr * 60 / rph;
        const row_end: usize = base + (gr + 1) * 60 / rph;

        if (gr % rph == 0) {
            const h24 = vmin + gr / rph;
            const ampm = if (h24 < 12) "AM" else "PM";
            var h12 = h24 % 12;
            if (h12 == 0) h12 = 12;
            var g: [8]u8 = undefined;
            const gs = std.fmt.bufPrint(&g, "{d:>2} {s} ", .{ h12, ampm }) catch "";
            try color.on(w, .gray);
            try padTrunc(w, gs, gutter);
            try color.off(w);
        } else {
            var k: usize = 0;
            while (k < gutter) : (k += 1) try w.writeByte(' ');
        }

        for (0..7) |d| {
            var found: ?Block = null;
            for (blocks) |b| {
                if (b.day != d) continue;
                if (b.start_min < row_end and b.end_min > row_start) {
                    found = b;
                    break;
                }
            }
            if (found) |b| {
                const bs: usize = b.start_min;
                const be: usize = b.end_min;
                const sr: usize = (bs - base) * rph / 60;
                const er: usize = ((be - base) * rph + 59) / 60;
                const height = if (er > sr) er - sr else 1;
                const rel = gr - sr;
                try color.bg(w, b.rgb);
                try color.fg(w, color.textOn(b.rgb));
                if (height == 1) {
                    var t: [32]u8 = undefined;
                    try padTrunc(w, fmtDur(&t, b.dur_secs), inner);
                } else if (rel == 0) {
                    try padTrunc(w, b.desc, inner);
                } else if (rel == 1 and height > 2) {
                    try padTrunc(w, b.project, inner);
                } else if (rel == height - 1) {
                    var t: [32]u8 = undefined;
                    const ds = fmtDur(&t, b.dur_secs);
                    if (b.running) {
                        var rb: [40]u8 = undefined;
                        try padTrunc(w, std.fmt.bufPrint(&rb, "{s} ▶", .{ds}) catch ds, inner);
                    } else {
                        try padTrunc(w, ds, inner);
                    }
                } else {
                    try padTrunc(w, "", inner);
                }
                try color.resetRaw(w);
            } else {
                try color.fg(w, tick);
                try w.writeAll("┊");
                try color.resetRaw(w);
                var k: usize = 1;
                while (k < inner) : (k += 1) try w.writeByte(' ');
            }
            try w.writeByte(' ');
        }
        try eol(w);
    }

    // ---- footer ----
    try color.on(w, .gray);
    try w.writeAll("←/→ or p/n: change week   t: this week   q: quit");
    try color.off(w);
    try w.writeAll("\x1b[J"); // clear anything below
    try w.flush();
}

/// Run the interactive week view. `client` null = offline demo over sample data.
fn loop(arena: std.mem.Allocator, io: Io, client: ?*api.Client, projects: []const cache.Entry, zone: localtz.Zone) !void {
    const term = Term.open(io) orelse return error.NoTerminal;
    defer term.close();

    var wbuf: [1 << 16]u8 = undefined;
    var fw = term.tty.writer(io, &wbuf);
    const w = &fw.interface;

    try w.writeAll("\x1b[?1049h\x1b[?25l"); // alt screen, hide cursor
    defer {
        w.writeAll("\x1b[?25h\x1b[?1049l") catch {};
        w.flush() catch {};
    }

    const cur_mon = currentMonday(io, zone);
    var week_mon = cur_mon;
    var need_fetch = true;
    var blocks: []const Block = &.{};
    var last: Size = .{ .cols = 0, .rows = 0 };

    while (true) {
        if (need_fetch) {
            try w.writeAll("\x1b[H");
            try color.on(w, .gray);
            try w.writeAll("Loading…");
            try color.off(w);
            try w.flush();
            blocks = fetchWeek(arena, io, client, projects, zone, week_mon, cur_mon) catch &.{};
            need_fetch = false;
            last = .{ .cols = 0, .rows = 0 }; // force a redraw
        }
        const size = winSize(term.fd);
        if (size.cols != last.cols or size.rows != last.rows) {
            try render(w, io, zone, week_mon, blocks, size);
            last = size;
        }

        var kb: [16]u8 = undefined;
        const n = posix.read(term.fd, &kb) catch continue; // waits up to VTIME
        if (n == 0) continue; // timeout → re-check size / refresh
        switch (kb[0]) {
            'q', 3 => return,
            'n' => {
                week_mon += 7;
                need_fetch = true;
            },
            'p' => {
                week_mon -= 7;
                need_fetch = true;
            },
            't' => if (week_mon != cur_mon) {
                week_mon = cur_mon;
                need_fetch = true;
            },
            27 => {
                if (n == 1) return; // bare Esc
                if (n >= 3 and kb[1] == '[') switch (kb[2]) {
                    'C' => {
                        week_mon += 7;
                        need_fetch = true;
                    },
                    'D' => {
                        week_mon -= 7;
                        need_fetch = true;
                    },
                    else => {},
                };
            },
            else => {},
        }
    }
}

/// `toggl viz` — live week view.
pub fn run(arena: std.mem.Allocator, io: Io, client: *api.Client, projects: []const cache.Entry, zone: localtz.Zone) !void {
    loop(arena, io, client, projects, zone) catch |err| switch (err) {
        error.NoTerminal => return error.NoTerminal,
        else => return err,
    };
}

/// `toggl vizdemo` — offline week view over sample data (no auth/network).
pub fn runDemo(arena: std.mem.Allocator, io: Io, zone: localtz.Zone) !void {
    loop(arena, io, null, &.{}, zone) catch |err| switch (err) {
        error.NoTerminal => return error.NoTerminal,
        else => return err,
    };
}

const gold: color.RGB = .{ .r = 122, .g = 95, .b = 38 };
const teal: color.RGB = .{ .r = 22, .g = 96, .b = 84 };
const slate: color.RGB = .{ .r = 74, .g = 74, .b = 86 };
const plum: color.RGB = .{ .r = 92, .g = 62, .b = 112 };

fn demoBlocks() []const Block {
    const S = struct {
        const data = [_]Block{
            .{ .day = 0, .start_min = 780, .end_min = 1270, .desc = "crypto concept", .project = "OsteoCoach", .dur_secs = 29451, .rgb = gold, .running = false },
            .{ .day = 1, .start_min = 540, .end_min = 620, .desc = "mac runners be dead", .project = "devops", .dur_secs = 4801, .rgb = slate, .running = false },
            .{ .day = 1, .start_min = 780, .end_min = 850, .desc = "sprint planning", .project = "OsteoCoach", .dur_secs = 4200, .rgb = gold, .running = false },
            .{ .day = 1, .start_min = 850, .end_min = 1065, .desc = "crypto concept", .project = "OsteoCoach", .dur_secs = 12900, .rgb = gold, .running = false },
            .{ .day = 1, .start_min = 1080, .end_min = 1238, .desc = "KLECOPY-564 Limesurvey", .project = "Klenico", .dur_secs = 9537, .rgb = teal, .running = false },
            .{ .day = 2, .start_min = 660, .end_min = 720, .desc = "Redesign + new team member", .project = "Internal", .dur_secs = 3600, .rgb = plum, .running = false },
            .{ .day = 2, .start_min = 780, .end_min = 1005, .desc = "KLECOPY-564 Limesurvey", .project = "Klenico: Neuentwicklung", .dur_secs = 13494, .rgb = teal, .running = false },
            .{ .day = 2, .start_min = 1020, .end_min = 1080, .desc = "KLECOPY-590 filter visibility", .project = "Klenico", .dur_secs = 3600, .rgb = teal, .running = false },
            .{ .day = 3, .start_min = 540, .end_min = 615, .desc = "KLECOPY-590 filter visibility", .project = "Klenico", .dur_secs = 4500, .rgb = teal, .running = false },
            .{ .day = 3, .start_min = 780, .end_min = 1095, .desc = "KLECOPY-561 Halsana Questionnaire", .project = "Klenico", .dur_secs = 18900, .rgb = teal, .running = false },
            .{ .day = 3, .start_min = 1100, .end_min = 1265, .desc = "KLECOPY-590 filter visibility", .project = "Klenico", .dur_secs = 9900, .rgb = teal, .running = false },
            .{ .day = 4, .start_min = 480, .end_min = 615, .desc = "O.Ntwk", .project = "OsteoCoach", .dur_secs = 8100, .rgb = gold, .running = false },
            .{ .day = 4, .start_min = 780, .end_min = 1220, .desc = "KLECOPY-561 Halsana Questionnaire", .project = "Klenico", .dur_secs = 26400, .rgb = teal, .running = true },
        };
    };
    return &S.data;
}
