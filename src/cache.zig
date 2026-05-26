const std = @import("std");
const Io = std.Io;
const api = @import("api.zig");

/// How long a cached project list is considered fresh.
pub const ttl_seconds: i64 = 24 * 60 * 60;

/// Bump whenever `Entry` gains fields that callers rely on. A cache written
/// with an older version is treated as stale, so `ensureCache` silently
/// rebuilds it on the next use — no user-visible migration step.
pub const schema_version: u32 = 2;

/// A single pickable choice: a project, or a project+task ("sub-project").
/// `label` is the human-readable, fuzzy-matchable string, e.g.
/// "Acme / Backend" or "Acme / Backend / Auth rework".
pub const Entry = struct {
    label: []const u8,
    project_id: i64,
    task_id: ?i64 = null,
    /// The project's Toggl hex color (e.g. "#0b83d9"); empty if unknown. Used by
    /// `toggl viz` to color blocks the same as the web UI.
    color: []const u8 = "",
    /// Project's billable flag, mirrored so creates can satisfy workspaces
    /// that require billable entries on billable projects.
    billable: bool = false,
};

/// The on-disk cache document.
pub const Cache = struct {
    /// Schema version the file was written with. Defaults to 0 so caches
    /// produced before this field existed are detected as outdated.
    schema_version: u32 = 0,
    synced_at: i64 = 0,
    entries: []Entry = &.{},

    pub fn isFresh(self: Cache, now: i64) bool {
        if (self.schema_version != schema_version) return false;
        return self.entries.len > 0 and (now - self.synced_at) < ttl_seconds;
    }
};

const dir_rel = ".config/toggl-cli";
const file_rel = ".config/toggl-cli/cache.json";

fn homeDir(io: Io, environ_map: *std.process.Environ.Map) !Io.Dir {
    const home = environ_map.get("HOME") orelse return error.NoHomeDir;
    return Io.Dir.openDirAbsolute(io, home, .{});
}

/// Load the cache, or null if it doesn't exist yet.
pub fn load(arena: std.mem.Allocator, io: Io, environ_map: *std.process.Environ.Map) !?Cache {
    var home = homeDir(io, environ_map) catch return null;
    defer home.close(io);

    const bytes = home.readFileAlloc(io, file_rel, arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try std.json.parseFromSliceLeaky(Cache, arena, bytes, .{ .ignore_unknown_fields = true });
}

pub fn save(arena: std.mem.Allocator, io: Io, environ_map: *std.process.Environ.Map, cache: Cache) !void {
    var home = try homeDir(io, environ_map);
    defer home.close(io);

    try home.createDirPath(io, dir_rel);

    var stamped = cache;
    stamped.schema_version = schema_version;

    var out: Io.Writer.Allocating = .init(arena);
    try std.json.Stringify.value(stamped, .{ .whitespace = .indent_2 }, &out.writer);

    try home.writeFile(io, .{ .sub_path = file_rel, .data = out.written() });
}

/// Fetch projects + tasks (+ clients for labels) and flatten them into a list
/// of pickable entries. Active projects become entries; each active task adds
/// a "<project> / <task>" entry.
pub fn build(arena: std.mem.Allocator, client: *api.Client) ![]Entry {
    const projects = try client.listProjects();
    const tasks = try client.listTasks();
    const clients = try client.listClients();

    var list: std.ArrayList(Entry) = .empty;

    for (projects) |p| {
        if (!p.active) continue;
        try list.append(arena, .{
            .label = try projectLabel(arena, clients, p),
            .project_id = p.id,
            .task_id = null,
            .color = p.color,
            .billable = p.billable,
        });
    }

    for (tasks) |t| {
        if (!t.active) continue;
        const p = findProject(projects, t.project_id) orelse continue;
        const plabel = try projectLabel(arena, clients, p);
        try list.append(arena, .{
            .label = try std.fmt.allocPrint(arena, "{s} / {s}", .{ plabel, t.name }),
            .project_id = t.project_id,
            .task_id = t.id,
            .color = p.color, // tasks inherit their project's color
            .billable = p.billable, // tasks inherit billability from project
        });
    }

    return list.items;
}

fn projectLabel(arena: std.mem.Allocator, clients: []const api.Client.ClientInfo, p: api.Client.Project) ![]const u8 {
    if (p.client_id) |cid| {
        if (clientName(clients, cid)) |cname| {
            return std.fmt.allocPrint(arena, "{s} / {s}", .{ cname, p.name });
        }
    }
    return p.name;
}

fn clientName(clients: []const api.Client.ClientInfo, id: i64) ?[]const u8 {
    for (clients) |c| {
        if (c.id == id) return c.name;
    }
    return null;
}

fn findProject(projects: []const api.Client.Project, id: i64) ?api.Client.Project {
    for (projects) |p| {
        if (p.id == id) return p;
    }
    return null;
}
