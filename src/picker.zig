const std = @import("std");
const Io = std.Io;
const posix = std.posix;
const cache = @import("cache.zig");
const color = @import("color.zig");

/// Max list rows shown at once (window into the filtered results).
const max_rows: usize = 12;

pub const Options = struct {
    /// Header line shown above the list.
    title: []const u8 = "Select",
    /// Whether typing filters the list (true) or the list is a fixed menu.
    show_filter: bool = true,
    /// Pre-populated filter text (only used when show_filter is true).
    initial_filter: []const u8 = "",
};

/// A controlling terminal in raw mode. Reading keys and drawing the UI both go
/// through /dev/tty so the picker works even when stdin/stdout are redirected.
const Term = struct {
    tty: Io.File,
    io: Io,
    fd: posix.fd_t,
    original: posix.termios,

    /// Enter raw mode, or null if there's no usable terminal.
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
        // No echo, no line buffering, handle signals ourselves so the deferred
        // restore always runs. Disable CR->NL translation so the Enter key
        // arrives as CR (13) and Ctrl-J (LF, 10) stays free for navigation.
        var raw = original;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
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

/// Pick one of `items` (display strings) and return its index, or null on
/// cancel (Esc/Ctrl-C) or when there's no terminal.
pub fn pickIndex(arena: std.mem.Allocator, io: Io, items: []const []const u8, opts: Options) !?usize {
    if (items.len == 0) return null;

    const term = Term.open(io) orelse return null;
    defer term.close();

    var wbuf: [8192]u8 = undefined;
    var fw = term.tty.writer(io, &wbuf);
    const w = &fw.interface;

    try w.writeAll("\x1b[?25l"); // hide cursor
    try w.flush();
    defer {
        w.writeAll("\x1b[?25h") catch {};
        w.flush() catch {};
    }

    var filter: std.ArrayList(u8) = .empty;
    if (opts.show_filter) try filter.appendSlice(arena, opts.initial_filter);

    var matches: std.ArrayList(usize) = .empty;
    try recompute(arena, items, filter.items, &matches);

    var selected: usize = 0;
    var offset: usize = 0;
    var prev_lines: usize = 0;

    while (true) {
        prev_lines = try render(w, items, matches.items, selected, offset, filter.items, opts, prev_lines);

        var kbuf: [32]u8 = undefined;
        const n = posix.read(term.fd, &kbuf) catch return null;
        if (n == 0) continue;

        const b = kbuf[0];
        switch (b) {
            '\r' => { // Enter (CR; ICRNL is disabled so LF means Ctrl-J)
                if (matches.items.len > 0) {
                    try clearFrame(w, prev_lines);
                    return matches.items[selected];
                }
            },
            3 => { // Ctrl-C
                try clearFrame(w, prev_lines);
                return null;
            },
            27 => { // Esc, or an escape sequence (arrow keys)
                if (n == 1) {
                    try clearFrame(w, prev_lines);
                    return null;
                }
                if (n >= 3 and kbuf[1] == '[') switch (kbuf[2]) {
                    'A' => moveUp(&selected, &offset),
                    'B' => moveDown(&selected, &offset, matches.items.len),
                    else => {},
                };
            },
            // Vim-friendly navigation that works even while filtering:
            // Ctrl-J/Ctrl-N down, Ctrl-K/Ctrl-P up (Telescope-style).
            10, 14 => moveDown(&selected, &offset, matches.items.len),
            11, 16 => moveUp(&selected, &offset),
            127, 8 => if (opts.show_filter) { // Backspace
                _ = filter.pop();
                try recompute(arena, items, filter.items, &matches);
                selected = 0;
                offset = 0;
            },
            else => {
                if (opts.show_filter) {
                    // Typing filters; printable bytes (incl. j/k) are filter text.
                    var changed = false;
                    for (kbuf[0..n]) |c| {
                        if (c >= 0x20 and c < 0x7f) {
                            try filter.append(arena, c);
                            changed = true;
                        }
                    }
                    if (changed) {
                        try recompute(arena, items, filter.items, &matches);
                        selected = 0;
                        offset = 0;
                    }
                } else {
                    // Fixed menu (no filtering): plain hjkl navigation.
                    // h/l have no meaning in a single column, like left/right.
                    switch (b) {
                        'j' => moveDown(&selected, &offset, matches.items.len),
                        'k' => moveUp(&selected, &offset),
                        else => {},
                    }
                }
            },
        }
    }
}

/// Convenience wrapper: pick a cached project/task entry by its label.
pub fn pick(arena: std.mem.Allocator, io: Io, entries: []const cache.Entry, initial_filter: []const u8) !?cache.Entry {
    if (entries.len == 0) return null;
    const labels = try arena.alloc([]const u8, entries.len);
    for (entries, 0..) |e, i| {
        var lb: Io.Writer.Allocating = .init(arena);
        try color.write(&lb.writer, .cyan, e.label);
        labels[i] = lb.written();
    }
    const idx = try pickIndex(arena, io, labels, .{
        .title = "Pick a project — type to filter, ^J/^K or arrows move, Enter select, Esc skip",
        .show_filter = true,
        .initial_filter = initial_filter,
    });
    return if (idx) |j| entries[j] else null;
}

/// Edit a single line of text in raw mode, pre-filled with `initial`. Returns
/// the edited string (arena-owned), or null if cancelled with Esc (caller
/// treats null as "keep the old value").
pub fn readLine(arena: std.mem.Allocator, io: Io, prompt: []const u8, initial: []const u8) !?[]const u8 {
    const term = Term.open(io) orelse return null;
    defer term.close();

    var wbuf: [4096]u8 = undefined;
    var fw = term.tty.writer(io, &wbuf);
    const w = &fw.interface;

    try w.writeAll("\x1b[?25h"); // show cursor while editing
    defer {
        w.writeAll("\r\x1b[2K") catch {}; // erase the input line on exit
        w.flush() catch {};
    }

    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, initial);
    var cursor: usize = buf.items.len;

    while (true) {
        // Redraw the single line and place the cursor.
        try w.writeAll("\r\x1b[2K");
        try color.on(w, .bold);
        try w.writeAll(prompt);
        try color.off(w);
        try w.print("{s}\r", .{buf.items});
        const col = prompt.len + cursor;
        if (col > 0) try w.print("\x1b[{d}C", .{col});
        try w.flush();

        var kbuf: [32]u8 = undefined;
        const n = posix.read(term.fd, &kbuf) catch return null;
        if (n == 0) continue;

        const b = kbuf[0];
        switch (b) {
            '\r', '\n' => return try arena.dupe(u8, buf.items),
            3 => return null, // Ctrl-C
            27 => {
                if (n == 1) return null; // Esc = keep old value
                if (n >= 3 and kbuf[1] == '[') switch (kbuf[2]) {
                    'C' => if (cursor < buf.items.len) {
                        cursor += 1;
                    }, // right
                    'D' => if (cursor > 0) {
                        cursor -= 1;
                    }, // left
                    'H' => cursor = 0, // Home
                    'F' => cursor = buf.items.len, // End
                    else => {},
                };
            },
            127, 8 => if (cursor > 0) { // Backspace
                _ = buf.orderedRemove(cursor - 1);
                cursor -= 1;
            },
            21 => { // Ctrl-U: clear line
                buf.clearRetainingCapacity();
                cursor = 0;
            },
            else => {
                for (kbuf[0..n]) |c| {
                    if (c >= 0x20 and c < 0x7f) {
                        try buf.insert(arena, cursor, c);
                        cursor += 1;
                    }
                }
            },
        }
    }
}

fn moveUp(selected: *usize, offset: *usize) void {
    if (selected.* == 0) return;
    selected.* -= 1;
    if (selected.* < offset.*) offset.* = selected.*;
}

fn moveDown(selected: *usize, offset: *usize, count: usize) void {
    if (count == 0 or selected.* + 1 >= count) return;
    selected.* += 1;
    if (selected.* >= offset.* + max_rows) offset.* = selected.* - max_rows + 1;
}

fn recompute(
    arena: std.mem.Allocator,
    items: []const []const u8,
    filter: []const u8,
    matches: *std.ArrayList(usize),
) !void {
    matches.clearRetainingCapacity();
    for (items, 0..) |s, i| {
        if (fuzzyMatch(s, filter)) try matches.append(arena, i);
    }
}

/// Case-insensitive subsequence match: every char of `needle` appears in
/// `haystack` in order. Empty needle matches everything.
fn fuzzyMatch(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    var ni: usize = 0;
    for (haystack) |hc| {
        if (std.ascii.toLower(hc) == std.ascii.toLower(needle[ni])) {
            ni += 1;
            if (ni == needle.len) return true;
        }
    }
    return false;
}

fn render(
    w: *Io.Writer,
    items: []const []const u8,
    matches: []const usize,
    selected: usize,
    offset: usize,
    filter: []const u8,
    opts: Options,
    prev_lines: usize,
) !usize {
    if (prev_lines > 0) try w.print("\x1b[{d}A", .{prev_lines});
    try w.writeAll("\r\x1b[0J"); // column 0, clear to end of screen

    var lines: usize = 0;

    try color.on(w, .bold);
    try w.writeAll(opts.title);
    try color.off(w);
    try color.on(w, .gray);
    try w.print("  ({d})", .{matches.len});
    try color.off(w);
    try w.writeByte('\n');
    lines += 1;
    if (opts.show_filter) {
        try w.print("\x1b[1m> \x1b[0m{s}\n", .{filter});
        lines += 1;
    }

    if (matches.len == 0) {
        try color.write(w, .dim, "  (no matches)\n");
        lines += 1;
    } else {
        const visible = @min(max_rows, matches.len - offset);
        var i: usize = 0;
        while (i < visible) : (i += 1) {
            const mi = offset + i;
            const label = items[matches[mi]];
            if (mi == selected) {
                // Reverse-video selection bar. Strip the label's own color
                // codes first, so an embedded reset can't cancel the highlight
                // partway across the row.
                try w.writeAll("\x1b[7m> ");
                try writeStripped(w, label);
                try w.writeAll("\x1b[0m\n");
            } else {
                try w.print("  {s}\n", .{label});
            }
            lines += 1;
        }
    }

    try w.flush();
    return lines;
}

/// Write `s` to `w` with any ANSI escape sequences (ESC `[` … final-byte)
/// removed. Used to render the selected row as a clean reverse-video bar even
/// when the label carries its own colors.
fn writeStripped(w: *Io.Writer, s: []const u8) !void {
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            // Skip until the sequence's final byte (0x40–0x7e), e.g. 'm'.
            while (i < s.len and (s[i] < 0x40 or s[i] > 0x7e)) : (i += 1) {}
            if (i < s.len) i += 1; // consume the final byte
        } else {
            try w.writeByte(s[i]);
            i += 1;
        }
    }
}

/// Erase the rendered frame, leaving the cursor where the picker started.
fn clearFrame(w: *Io.Writer, prev_lines: usize) !void {
    if (prev_lines > 0) try w.print("\x1b[{d}A", .{prev_lines});
    try w.writeAll("\r\x1b[0J");
    try w.flush();
}

test "writeStripped removes ANSI escape sequences" {
    var out: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    // Mixed styled text: bold + cyan label, reset, plain tail.
    try writeStripped(&out.writer, "\x1b[1m\x1b[36mAcme / Backend\x1b[0m — running 5m");
    try std.testing.expectEqualStrings("Acme / Backend — running 5m", out.written());

    // No escapes: passes through unchanged.
    out.clearRetainingCapacity();
    try writeStripped(&out.writer, "plain text");
    try std.testing.expectEqualStrings("plain text", out.written());
}

test "fuzzyMatch is a case-insensitive subsequence" {
    try std.testing.expect(fuzzyMatch("Acme / Backend", ""));
    try std.testing.expect(fuzzyMatch("Acme / Backend", "back"));
    try std.testing.expect(fuzzyMatch("Acme / Backend", "ABK"));
    try std.testing.expect(fuzzyMatch("Globex / Data pipeline", "gdp"));
    try std.testing.expect(!fuzzyMatch("Acme / Backend", "frontend"));
    try std.testing.expect(!fuzzyMatch("ab", "abc"));
}
