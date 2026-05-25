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
    // Side-by-side layout for overlaps, filled by `layoutDays`: `lane` is this
    // block's column within its overlap cluster, `lanes` the cluster's width.
    lane: u8 = 0,
    lanes: u8 = 1,
};

const max_lanes = 8;

/// Assign overlap lanes per day (calendar-style): within each day, group
/// transitively-overlapping blocks into a cluster, give each a lane (greedy
/// first-fit), and record the cluster's lane count so the renderer can split
/// the day's column. Mutates and sorts `blocks`.
fn layoutDays(blocks: []Block) void {
    std.mem.sort(Block, blocks, {}, struct {
        fn lt(_: void, a: Block, b: Block) bool {
            if (a.day != b.day) return a.day < b.day;
            if (a.start_min != b.start_min) return a.start_min < b.start_min;
            return a.end_min < b.end_min;
        }
    }.lt);

    var i: usize = 0;
    while (i < blocks.len) {
        const d = blocks[i].day;
        var dj = i;
        while (dj < blocks.len and blocks[dj].day == d) dj += 1;

        var c = i;
        while (c < dj) {
            // Extend the cluster while the next block starts before it ends.
            var cluster_end: u16 = blocks[c].end_min;
            var cj = c + 1;
            while (cj < dj and blocks[cj].start_min < cluster_end) {
                if (blocks[cj].end_min > cluster_end) cluster_end = blocks[cj].end_min;
                cj += 1;
            }
            // First-fit lane assignment within [c, cj).
            var lane_end = [_]u16{0} ** max_lanes;
            var used: usize = 0;
            var k = c;
            while (k < cj) : (k += 1) {
                var placed = false;
                var l: usize = 0;
                while (l < used) : (l += 1) {
                    if (lane_end[l] <= blocks[k].start_min) {
                        blocks[k].lane = @intCast(l);
                        lane_end[l] = blocks[k].end_min;
                        placed = true;
                        break;
                    }
                }
                if (!placed) {
                    if (used < max_lanes) {
                        blocks[k].lane = @intCast(used);
                        lane_end[used] = blocks[k].end_min;
                        used += 1;
                    } else {
                        blocks[k].lane = max_lanes - 1; // overflow: stack in last lane
                    }
                }
            }
            const L: u8 = @intCast(if (used == 0) 1 else used);
            k = c;
            while (k < cj) : (k += 1) blocks[k].lanes = L;
            c = cj;
        }
        i = dj;
    }
}

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
    // Zero-init so a failed ioctl reads as col==0 → fallback; avoids a per-OS
    // errno check (linux's `E` has no `init`).
    var ws: posix.winsize = std.mem.zeroes(posix.winsize);
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.ioctl(fd, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws)),
        else => _ = std.c.ioctl(fd, 0x40087468, &ws),
    }
    if (ws.col == 0) return .{ .cols = 120, .rows = 40 };
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

/// Append one block per local day the entry touches inside the visible week, so
/// entries that span midnight (or start before the week and run into it) show on
/// each day, clipped to that day. `dur_secs` is the per-day segment length, so
/// daily totals stay correct.
fn appendBlocks(list: *std.ArrayList(Block), arena: std.mem.Allocator, e: api.Client.TimeEntry, projects: []const cache.Entry, zone: localtz.Zone, week_mon: i64, now: i64) !void {
    const su = if (e.start) |s| (timefmt.parseRfc3339(s) orelse return) else return;
    const running = e.duration < 0;
    const eu = if (running) now else su + e.duration;
    if (eu <= su) return;

    const slocal = su + zone.offsetAt(su);
    const elocal = eu + zone.offsetAt(eu);
    const start_day = @divFloor(slocal, 86400);
    const end_day = @divFloor(elocal - 1, 86400); // inclusive last day with content

    const desc: []const u8 = if (e.description) |d| (if (d.len > 0) d else "(no description)") else "(no description)";
    var proj: []const u8 = "(no project)";
    var rgb = no_project;
    if (e.project_id) |pid| {
        const info = lookup(projects, pid, e.task_id);
        proj = info.label;
        rgb = info.rgb;
    }

    var day = @max(start_day, week_mon);
    const last = @min(end_day, week_mon + 6);
    while (day <= last) : (day += 1) {
        const day0 = day * 86400;
        const seg_start = @max(slocal, day0);
        const seg_end = @min(elocal, day0 + 86400);
        if (seg_end <= seg_start) continue;
        const smin: u16 = @intCast(@divFloor(seg_start - day0, 60));
        var emin: i64 = @divFloor(seg_end - day0 + 59, 60); // ceil so a partial minute still shows
        if (emin > 1440) emin = 1440;
        if (emin <= smin) emin = @as(i64, smin) + 1;
        try list.append(arena, .{
            .day = @intCast(day - week_mon),
            .start_min = smin,
            .end_min = @intCast(emin),
            .desc = desc,
            .project = proj,
            .dur_secs = seg_end - seg_start,
            .rgb = rgb,
            .running = running,
        });
    }
}

fn fetchWeek(arena: std.mem.Allocator, io: Io, client: ?*api.Client, projects: []const cache.Entry, zone: localtz.Zone, week_mon: i64, cur_mon: i64) ![]const Block {
    if (client) |c| {
        const sd = try dateStr(arena, week_mon - 1);
        const ed = try dateStr(arena, week_mon + 8);
        const entries = try c.list(sd, ed);
        const now = timefmt.nowUnix(io);
        var list: std.ArrayList(Block) = .empty;
        for (entries) |e| try appendBlocks(&list, arena, e, projects, zone, week_mon, now);
        return list.items;
    }
    // Demo: show the sample week only on the current week.
    if (week_mon == cur_mon) return demoBlocks();
    return &.{};
}

/// Write `text` to `w` truncated/padded to `width` columns. Truncation lands on
/// UTF-8 codepoint boundaries (so multi-byte chars aren't split into mojibake);
/// each codepoint counts as one column. Wide glyphs (CJK/emoji) may still
/// under-pad slightly, but no sequence is ever cut mid-character.
fn padTrunc(w: *Io.Writer, text: []const u8, width: usize) !void {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len and cols < width) {
        const seq = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const n = @min(@as(usize, seq), text.len - i);
        try w.writeAll(text[i .. i + n]);
        i += n;
        cols += 1;
    }
    while (cols < width) : (cols += 1) try w.writeByte(' ');
}

fn eol(w: *Io.Writer) !void {
    try w.writeAll("\x1b[K\n"); // clear to end of line + newline
}

/// Render block `b`'s content for grid row `gr` into `width` columns: filled in
/// the project color, with description / project / duration on successive rows
/// (or just the duration when the block is one row tall).
fn renderCell(w: *Io.Writer, b: Block, gr: usize, base: usize, rph: usize, width: usize) !void {
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
        try padTrunc(w, fmtDur(&t, b.dur_secs), width);
    } else if (rel == 0) {
        try padTrunc(w, b.desc, width);
    } else if (rel == 1 and height > 2) {
        try padTrunc(w, b.project, width);
    } else if (rel == height - 1) {
        var t: [32]u8 = undefined;
        const ds = fmtDur(&t, b.dur_secs);
        if (b.running) {
            var rb: [40]u8 = undefined;
            try padTrunc(w, std.fmt.bufPrint(&rb, "{s} ▶", .{ds}) catch ds, width);
        } else {
            try padTrunc(w, ds, width);
        }
    } else {
        try padTrunc(w, "", width);
    }
    try color.resetRaw(w);
}

fn render(w: *Io.Writer, io: Io, zone: localtz.Zone, week_mon: i64, blocks: []const Block, size: Size, load_failed: bool) !void {
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
            // Collect the blocks active in this cell, keyed by lane. Any blocks
            // active at the same instant overlap, so they share a lane count.
            var lane_block = [_]?Block{null} ** max_lanes;
            var lanes: usize = 1;
            var any = false;
            for (blocks) |b| {
                if (b.day != d) continue;
                if (b.start_min < row_end and b.end_min > row_start) {
                    any = true;
                    lanes = b.lanes;
                    lane_block[@as(usize, b.lane)] = b;
                }
            }
            if (!any) {
                try color.fg(w, tick);
                try w.writeAll("┊");
                try color.resetRaw(w);
                var k: usize = 1;
                while (k < inner) : (k += 1) try w.writeByte(' ');
            } else {
                if (lanes < 1) lanes = 1;
                if (lanes > max_lanes) lanes = max_lanes;
                const base_w = inner / lanes;
                const extra = inner % lanes;
                var lane: usize = 0;
                while (lane < lanes) : (lane += 1) {
                    const wl = base_w + (if (lane < extra) @as(usize, 1) else 0);
                    if (lane_block[lane]) |b| {
                        try renderCell(w, b, gr, base, rph, wl);
                    } else {
                        try padTrunc(w, "", wl); // empty lane within the cluster
                    }
                }
            }
            try w.writeByte(' ');
        }
        try eol(w);
    }

    // ---- footer ----
    if (load_failed) {
        try color.on(w, .red);
        try w.writeAll("⚠ couldn't load this week (rate-limited or beyond ~90 days)   ");
        try color.off(w);
    }
    try color.on(w, .gray);
    try w.writeAll("←/→ or p/n: week   t: this week   r: refresh   q: quit");
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

    // We own the alt-screen, so API errors must not print to stderr over it.
    if (client) |c| c.quiet = true;

    const cur_mon = currentMonday(io, zone);
    var week_mon = cur_mon;
    var need_fetch = true;
    var blocks: []const Block = &.{};
    var load_failed = false;
    var last: Size = .{ .cols = 0, .rows = 0 };

    while (true) {
        if (need_fetch) {
            try w.writeAll("\x1b[H");
            try color.on(w, .gray);
            try w.writeAll("Loading…");
            try color.off(w);
            try w.flush();
            load_failed = false;
            const fetched = fetchWeek(arena, io, client, projects, zone, week_mon, cur_mon) catch blk: {
                load_failed = true;
                break :blk &.{};
            };
            const laid = try arena.dupe(Block, fetched); // mutable copy to annotate
            layoutDays(laid); // assign overlap lanes
            blocks = laid;
            need_fetch = false;
            last = .{ .cols = 0, .rows = 0 }; // force a redraw
        }
        const size = winSize(term.fd);
        if (size.cols != last.cols or size.rows != last.rows) {
            try render(w, io, zone, week_mon, blocks, size, load_failed);
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
            'r' => need_fetch = true, // re-fetch this week (also refreshes a running timer)
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

test "layoutDays splits overlapping blocks into lanes per cluster" {
    const mk = struct {
        fn b(day: u8, s: u16, e: u16) Block {
            return .{ .day = day, .start_min = s, .end_min = e, .desc = "", .project = "", .dur_secs = 0, .rgb = .{ .r = 0, .g = 0, .b = 0 }, .running = false };
        }
    }.b;
    var blocks = [_]Block{
        mk(1, 780, 1065), // A: overlaps B
        mk(1, 780, 880), // B
        mk(1, 1080, 1200), // C: separate cluster
        mk(2, 600, 660), // D: adjacent to E (touch, no overlap)
        mk(2, 660, 720), // E
    };
    layoutDays(&blocks);
    // Sorted: day1 [B(780,880), A(780,1065), C], day2 [D, E].
    try std.testing.expectEqual(@as(u8, 2), blocks[0].lanes); // B in 2-lane cluster
    try std.testing.expectEqual(@as(u8, 0), blocks[0].lane);
    try std.testing.expectEqual(@as(u8, 2), blocks[1].lanes); // A
    try std.testing.expectEqual(@as(u8, 1), blocks[1].lane);
    try std.testing.expectEqual(@as(u8, 1), blocks[2].lanes); // C alone
    try std.testing.expectEqual(@as(u8, 1), blocks[3].lanes); // D (adjacent ≠ overlap)
    try std.testing.expectEqual(@as(u8, 1), blocks[4].lanes); // E
}

test "appendBlocks splits an entry spanning midnight into per-day segments" {
    const a = std.testing.allocator;
    var list: std.ArrayList(Block) = .empty;
    defer list.deinit(a);
    const zone: localtz.Zone = .{}; // UTC (offset 0)
    const day: i64 = 20000;
    const su = day * 86400 + 23 * 3600; // 23:00 UTC
    var buf: [40]u8 = undefined;
    const start_str = try timefmt.epochToRfc3339(su, &buf);
    const e = api.Client.TimeEntry{ .id = 1, .start = start_str, .duration = 3 * 3600 }; // ends 02:00 next day
    try appendBlocks(&list, a, e, &.{}, zone, day, 0);

    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqual(@as(u8, 0), list.items[0].day);
    try std.testing.expectEqual(@as(u16, 1380), list.items[0].start_min); // 23:00
    try std.testing.expectEqual(@as(u16, 1440), list.items[0].end_min); // 24:00
    try std.testing.expectEqual(@as(u8, 1), list.items[1].day);
    try std.testing.expectEqual(@as(u16, 0), list.items[1].start_min); // 00:00
    try std.testing.expectEqual(@as(u16, 120), list.items[1].end_min); // 02:00
}

test "padTrunc keeps UTF-8 whole and pads to width" {
    const a = std.testing.allocator;
    var out: Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try padTrunc(&out.writer, "café", 3); // 'é' is 2 bytes — dropped whole, not split
    try std.testing.expectEqualStrings("caf", out.written());
    out.clearRetainingCapacity();
    try padTrunc(&out.writer, "café", 4); // fits exactly, no padding
    try std.testing.expectEqualStrings("café", out.written());
    out.clearRetainingCapacity();
    try padTrunc(&out.writer, "ab", 4); // short — padded with spaces
    try std.testing.expectEqualStrings("ab  ", out.written());
}

fn demoBlocks() []const Block {
    const S = struct {
        const data = [_]Block{
            .{ .day = 0, .start_min = 780, .end_min = 1270, .desc = "crypto concept", .project = "OsteoCoach", .dur_secs = 29451, .rgb = gold, .running = false },
            .{ .day = 1, .start_min = 540, .end_min = 620, .desc = "mac runners be dead", .project = "devops", .dur_secs = 4801, .rgb = slate, .running = false },
            .{ .day = 1, .start_min = 780, .end_min = 1065, .desc = "crypto concept", .project = "OsteoCoach", .dur_secs = 17100, .rgb = gold, .running = false },
            .{ .day = 1, .start_min = 780, .end_min = 880, .desc = "sprint planning", .project = "Internal", .dur_secs = 6000, .rgb = plum, .running = false },
            .{ .day = 1, .start_min = 1080, .end_min = 1238, .desc = "KLECOPY-564 Limesurvey", .project = "Klenico", .dur_secs = 9537, .rgb = teal, .running = false },
            .{ .day = 2, .start_min = 660, .end_min = 720, .desc = "Redesign + new team member", .project = "Internal", .dur_secs = 3600, .rgb = plum, .running = false },
            .{ .day = 2, .start_min = 780, .end_min = 1005, .desc = "KLECOPY-564 Limesurvey", .project = "Klenico: Neuentwicklung", .dur_secs = 13494, .rgb = teal, .running = false },
            .{ .day = 2, .start_min = 1020, .end_min = 1080, .desc = "KLECOPY-590 filter visibility", .project = "Klenico", .dur_secs = 3600, .rgb = teal, .running = false },
            .{ .day = 3, .start_min = 540, .end_min = 615, .desc = "KLECOPY-590 filter visibility", .project = "Klenico", .dur_secs = 4500, .rgb = teal, .running = false },
            .{ .day = 3, .start_min = 780, .end_min = 1095, .desc = "KLECOPY-561 Halsana Questionnaire", .project = "Klenico", .dur_secs = 18900, .rgb = teal, .running = false },
            .{ .day = 3, .start_min = 1100, .end_min = 1265, .desc = "KLECOPY-590 filter visibility", .project = "Klenico", .dur_secs = 9900, .rgb = teal, .running = false },
            .{ .day = 4, .start_min = 480, .end_min = 615, .desc = "O.Ntwk", .project = "OsteoCoach", .dur_secs = 8100, .rgb = gold, .running = false },
            .{ .day = 4, .start_min = 780, .end_min = 1220, .desc = "KLECOPY-561 Halsana Questionnaire", .project = "Klenico", .dur_secs = 26400, .rgb = teal, .running = true },
            // A late-night entry spanning midnight (Sat 22:00 → Sun 02:00), shown
            // as two day-clipped blocks — what the live splitter produces.
            .{ .day = 5, .start_min = 1320, .end_min = 1440, .desc = "late-night deploy", .project = "devops", .dur_secs = 7200, .rgb = slate, .running = false },
            .{ .day = 6, .start_min = 0, .end_min = 120, .desc = "late-night deploy", .project = "devops", .dur_secs = 7200, .rgb = slate, .running = false },
        };
    };
    return &S.data;
}
