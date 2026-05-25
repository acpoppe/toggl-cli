//! Minimal ANSI color helpers built on top of `std.Io.Terminal`.
//!
//! "Should this process use color?" is a single global fact: it depends only on
//! the output stream and the environment (NO_COLOR / CLICOLOR_FORCE), never on
//! who's calling. So it's decided once at startup by `detect` and stored here,
//! rather than threaded through every print signature. The paint helpers no-op
//! when color is off, so call sites stay branch-free and piping
//! `toggl status | cat` (or setting NO_COLOR) yields clean, unstyled text.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Whether stdout / stderr each support color. Set once by `detect` /
/// `detectErr`; read by the paint helpers. Tracked separately because the two
/// streams can differ — e.g. `toggl start | cat` pipes stdout while stderr is
/// still a terminal. Default off so anything printed before detection (or if
/// detection fails) stays uncolored.
var enabled: bool = false;
var enabled_err: bool = false;

/// Ask `std.Io.Terminal` whether `file` should get color. It honors NO_COLOR
/// and CLICOLOR_FORCE and reports `no_color` when the stream isn't a terminal
/// (piped or redirected). Best-effort: any detection error means no color.
fn detectMode(io: Io, file: Io.File, env: *std.process.Environ.Map) bool {
    const no_color = if (env.get("NO_COLOR")) |v| v.len > 0 else false;
    const force = if (env.get("CLICOLOR_FORCE")) |v| v.len > 0 else false;
    const mode = Io.Terminal.Mode.detect(io, file, no_color, force) catch return false;
    return mode != .no_color;
}

/// Decide whether stdout gets color (pass `Io.File.stdout()`).
pub fn detect(io: Io, file: Io.File, env: *std.process.Environ.Map) void {
    enabled = detectMode(io, file, env);
}

/// Decide whether stderr gets color (pass `Io.File.stderr()`).
pub fn detectErr(io: Io, file: Io.File, env: *std.process.Environ.Map) void {
    enabled_err = detectMode(io, file, env);
}

pub fn isEnabled() bool {
    return enabled;
}

/// The terminal column count for `file`, or null if it can't be determined
/// (not a terminal, or the query failed). Uses TIOCGWINSZ directly since 0.16
/// has no std wrapper; the request value/ioctl ABI differ per OS.
pub fn width(file: Io.File) ?u16 {
    // Zero-init so a failed ioctl (which leaves the struct untouched) reads as
    // col==0 → "unknown" — avoids a per-OS errno check (linux's `E` has no
    // `init`), and the failure outcome is identical either way.
    var ws: std.posix.winsize = std.mem.zeroes(std.posix.winsize);
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.ioctl(file.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws)),
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            // TIOCGWINSZ on Darwin/BSD: _IOR('t', 104, struct winsize).
            const TIOCGWINSZ: c_int = 0x40087468;
            _ = std.c.ioctl(file.handle, TIOCGWINSZ, &ws);
        },
        else => return null,
    }
    return if (ws.col == 0) null else ws.col;
}

pub fn errEnabled() bool {
    return enabled_err;
}

/// Print an error/usage line to stderr, in red when stderr supports color.
/// `fmt` is comptime (as `std.debug.print` requires), so the codes can be
/// concatenated at comptime around it.
pub fn eprint(comptime fmt: []const u8, args: anytype) void {
    if (enabled_err)
        std.debug.print("\x1b[31m" ++ fmt ++ "\x1b[0m", args)
    else
        std.debug.print(fmt, args);
}

/// The subset of SGR styles this app uses, with their escape sequences.
pub const Style = enum {
    reset,
    bold,
    dim,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    /// Bright black — reads as gray, used for de-emphasized field labels.
    gray,

    fn seq(s: Style) []const u8 {
        return switch (s) {
            .reset => "\x1b[0m",
            .bold => "\x1b[1m",
            .dim => "\x1b[2m",
            .red => "\x1b[31m",
            .green => "\x1b[32m",
            .yellow => "\x1b[33m",
            .blue => "\x1b[34m",
            .magenta => "\x1b[35m",
            .cyan => "\x1b[36m",
            .gray => "\x1b[90m",
        };
    }
};

/// Begin a style (no-op when color is disabled). Pair with `off`. Several `on`
/// calls stack (e.g. bold + green); `off` clears them all with a single reset.
pub fn on(out: *Io.Writer, style: Style) !void {
    if (enabled) try out.writeAll(style.seq());
}

/// Reset all styling (no-op when color is disabled).
pub fn off(out: *Io.Writer) !void {
    if (enabled) try out.writeAll(Style.reset.seq());
}

/// Write `text` wrapped in `style` and a trailing reset — plain text when color
/// is off. For format args or stacked styles, use `on`/`off` directly.
pub fn write(out: *Io.Writer, style: Style, text: []const u8) !void {
    try on(out, style);
    try out.writeAll(text);
    try off(out);
}

// ---- RGB / true-color (for the `viz` calendar) -----------------------------

pub const RGB = struct { r: u8, g: u8, b: u8 };

/// How many colors the terminal can show. Decided once by `detectDepth`.
pub const Depth = enum { none, ansi16, ansi256, truecolor };
var depth: Depth = .none;

/// Decide the terminal's color depth from the environment. `none` when NO_COLOR
/// is set; truecolor when COLORTERM advertises it; 256 when TERM mentions 256;
/// otherwise basic 16-color.
pub fn detectDepth(env: *std.process.Environ.Map) void {
    if (env.get("NO_COLOR")) |v| if (v.len > 0) {
        depth = .none;
        return;
    };
    if (env.get("COLORTERM")) |ct| {
        if (std.mem.indexOf(u8, ct, "truecolor") != null or std.mem.indexOf(u8, ct, "24bit") != null) {
            depth = .truecolor;
            return;
        }
    }
    if (env.get("TERM")) |t| {
        if (std.mem.indexOf(u8, t, "256") != null) {
            depth = .ansi256;
            return;
        }
    }
    depth = .ansi16;
}

pub fn colorDepth() Depth {
    return depth;
}

/// Parse a "#rrggbb" hex color, or null if it isn't one.
pub fn parseHex(s: []const u8) ?RGB {
    if (s.len < 7 or s[0] != '#') return null;
    const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
    return .{ .r = r, .g = g, .b = b };
}

/// A stable, pleasant fallback color for a project that has no Toggl color yet
/// (keyed by id, so it stays consistent until the next `toggl sync`).
pub fn hashColor(seed: i64) RGB {
    const palette = [_]RGB{
        .{ .r = 0xc9, .g = 0x80, .b = 0x6b }, .{ .r = 0x16, .g = 0x60, .b = 0x54 },
        .{ .r = 0x56, .g = 0x6b, .b = 0xc9 }, .{ .r = 0x9c, .g = 0x6b, .b = 0xc9 },
        .{ .r = 0xc9, .g = 0x6b, .b = 0x9c }, .{ .r = 0x6b, .g = 0x9c, .b = 0xc9 },
        .{ .r = 0xc9, .g = 0xb0, .b = 0x6b }, .{ .r = 0x6b, .g = 0xc9, .b = 0x80 },
        .{ .r = 0xb0, .g = 0x6b, .b = 0x4f }, .{ .r = 0x4f, .g = 0x8b, .b = 0xb0 },
    };
    const idx: usize = @intCast(@mod(seed, @as(i64, palette.len)));
    return palette[idx];
}

/// A readable text color (near-white or near-black) for text on `bg_color`.
pub fn textOn(bg_color: RGB) RGB {
    // Rec.601 luma.
    const luma = (@as(u32, bg_color.r) * 299 + @as(u32, bg_color.g) * 587 + @as(u32, bg_color.b) * 114) / 1000;
    return if (luma > 150) .{ .r = 20, .g = 20, .b = 20 } else .{ .r = 240, .g = 240, .b = 240 };
}

fn comp6(v: u8) u16 {
    return @as(u16, v) * 5 / 255;
}

fn nearest256(c: RGB) u8 {
    return @intCast(16 + 36 * comp6(c.r) + 6 * comp6(c.g) + comp6(c.b));
}

const ansi16 = [16]RGB{
    .{ .r = 0, .g = 0, .b = 0 },       .{ .r = 205, .g = 0, .b = 0 },
    .{ .r = 0, .g = 205, .b = 0 },     .{ .r = 205, .g = 205, .b = 0 },
    .{ .r = 0, .g = 0, .b = 238 },     .{ .r = 205, .g = 0, .b = 205 },
    .{ .r = 0, .g = 205, .b = 205 },   .{ .r = 229, .g = 229, .b = 229 },
    .{ .r = 127, .g = 127, .b = 127 }, .{ .r = 255, .g = 0, .b = 0 },
    .{ .r = 0, .g = 255, .b = 0 },     .{ .r = 255, .g = 255, .b = 0 },
    .{ .r = 92, .g = 92, .b = 255 },   .{ .r = 255, .g = 0, .b = 255 },
    .{ .r = 0, .g = 255, .b = 255 },   .{ .r = 255, .g = 255, .b = 255 },
};

fn nearest16(c: RGB) usize {
    var best: usize = 0;
    var best_d: u32 = std.math.maxInt(u32);
    for (ansi16, 0..) |p, i| {
        const dr = @as(i32, c.r) - p.r;
        const dg = @as(i32, c.g) - p.g;
        const db = @as(i32, c.b) - p.b;
        const d: u32 = @intCast(dr * dr + dg * dg + db * db);
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

/// Set the background to `c`, choosing the best representation for the detected
/// depth. No-op when depth is `none`.
pub fn bg(out: *Io.Writer, c: RGB) !void {
    switch (depth) {
        .none => {},
        .truecolor => try out.print("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        .ansi256 => try out.print("\x1b[48;5;{d}m", .{nearest256(c)}),
        .ansi16 => {
            const i = nearest16(c);
            try out.print("\x1b[{d}m", .{if (i < 8) 40 + i else 100 + (i - 8)});
        },
    }
}

/// Set the foreground to `c` for the detected depth. No-op when depth is `none`.
pub fn fg(out: *Io.Writer, c: RGB) !void {
    switch (depth) {
        .none => {},
        .truecolor => try out.print("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b }),
        .ansi256 => try out.print("\x1b[38;5;{d}m", .{nearest256(c)}),
        .ansi16 => {
            const i = nearest16(c);
            try out.print("\x1b[{d}m", .{if (i < 8) 30 + i else 90 + (i - 8)});
        },
    }
}

/// Reset colors/attributes (always emitted; harmless on a mono terminal).
pub fn resetRaw(out: *Io.Writer) !void {
    try out.writeAll("\x1b[0m");
}
