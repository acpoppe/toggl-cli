const std = @import("std");
const Io = std.Io;

/// Persisted configuration, stored as JSON at
/// ~/.config/toggl-cli/config.json.
pub const Config = struct {
    api_token: []const u8 = "",
    /// The workspace new entries are created in. 0 means "not set yet" — we'll
    /// look up the account's default workspace from /me on demand.
    workspace_id: i64 = 0,
};

const dir_rel = ".config/toggl-cli";
const file_rel = ".config/toggl-cli/config.json";

fn homeDir(io: Io, environ_map: *std.process.Environ.Map) !Io.Dir {
    const home = environ_map.get("HOME") orelse return error.NoHomeDir;
    return Io.Dir.openDirAbsolute(io, home, .{});
}

/// Load the config file. A missing file is not an error — it just yields an
/// empty Config (so first-run `toggl auth` works).
pub fn load(arena: std.mem.Allocator, io: Io, environ_map: *std.process.Environ.Map) !Config {
    var home = homeDir(io, environ_map) catch return .{};
    defer home.close(io);

    const bytes = home.readFileAlloc(io, file_rel, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(Config, arena, bytes, .{ .ignore_unknown_fields = true });
}

/// Write the config file, creating ~/.config/toggl-cli/ if needed.
pub fn save(arena: std.mem.Allocator, io: Io, environ_map: *std.process.Environ.Map, cfg: Config) !void {
    var home = try homeDir(io, environ_map);
    defer home.close(io);

    try home.createDirPath(io, dir_rel);

    var out: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(cfg, .{ .whitespace = .indent_2 }, &out.writer);

    // The file holds the API token in plaintext, so keep it owner-only (0600).
    // `permissions` only applies when the file is created, so also chmod an
    // existing file to tighten it.
    try home.writeFile(io, .{
        .sub_path = file_rel,
        .data = out.written(),
        .flags = .{ .permissions = Io.File.Permissions.fromMode(0o600) },
    });
    var file = try home.openFile(io, file_rel, .{});
    defer file.close(io);
    try file.setPermissions(io, Io.File.Permissions.fromMode(0o600));
}

/// Human-readable path to the config file, for messages.
pub fn displayPath(arena: std.mem.Allocator, environ_map: *std.process.Environ.Map) []const u8 {
    const home = environ_map.get("HOME") orelse return file_rel;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ home, file_rel }) catch file_rel;
}
