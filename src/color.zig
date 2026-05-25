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
    var ws: std.posix.winsize = undefined;
    switch (builtin.os.tag) {
        .linux => {
            const rc = std.os.linux.ioctl(file.handle, std.os.linux.T.IOCGWINSZ, @intFromPtr(&ws));
            if (std.os.linux.E.init(rc) != .SUCCESS) return null;
        },
        .macos, .ios, .tvos, .watchos, .freebsd, .netbsd, .openbsd, .dragonfly => {
            // TIOCGWINSZ on Darwin/BSD: _IOR('t', 104, struct winsize).
            const TIOCGWINSZ: c_int = 0x40087468;
            if (std.c.ioctl(file.handle, TIOCGWINSZ, &ws) != 0) return null;
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
