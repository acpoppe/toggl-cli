const std = @import("std");
const Io = std.Io;
const timefmt = @import("timefmt.zig");
const color = @import("color.zig");

const base_url = "https://api.track.toggl.com/api/v9";
const user_agent = "toggl-cli (https://github.com/)";

/// A thin client over the Toggl Track API v9.
///
/// Everything is allocated from `arena`, which is expected to live for the
/// whole process, so the returned slices stay valid and we never free.
pub const Client = struct {
    http: std.http.Client,
    arena: std.mem.Allocator,
    io: Io,
    /// "Basic <base64(token:api_token)>"
    auth_header: []const u8,
    /// Cached workspace id. 0 means "not known yet".
    workspace_id: i64 = 0,

    pub fn init(arena: std.mem.Allocator, io: Io, token: []const u8) !Client {
        // Toggl uses HTTP Basic auth with the API token as the username and the
        // literal string "api_token" as the password.
        const raw = try std.fmt.allocPrint(arena, "{s}:api_token", .{token});
        const encoder = std.base64.standard.Encoder;
        const encoded = try arena.alloc(u8, encoder.calcSize(raw.len));
        const b64 = encoder.encode(encoded, raw);
        const header = try std.fmt.allocPrint(arena, "Basic {s}", .{b64});

        return .{
            .http = .{ .allocator = arena, .io = io },
            .arena = arena,
            .io = io,
            .auth_header = header,
        };
    }

    pub fn deinit(self: *Client) void {
        self.http.deinit();
    }

    // ---- low-level request ------------------------------------------------

    const Response = struct {
        status: u16,
        body: []const u8,

        fn ok(self: Response) bool {
            return self.status >= 200 and self.status < 300;
        }
    };

    fn request(self: *Client, method: std.http.Method, url: []const u8, payload: ?[]const u8) !Response {
        // `HttpConnectionClosing` means a pooled keep-alive connection was
        // closed by the server before we reused it. We don't pool (keep_alive
        // is off below), but retry once as a belt-and-suspenders against a
        // connection that drops mid-flight.
        return self.requestOnce(method, url, payload) catch |err| switch (err) {
            error.HttpConnectionClosing => self.requestOnce(method, url, payload),
            else => err,
        };
    }

    fn requestOnce(self: *Client, method: std.http.Method, url: []const u8, payload: ?[]const u8) !Response {
        var sink: Io.Writer.Allocating = .init(self.arena);

        // std.http's fetch() routes a null payload through `sendBodiless`, which
        // asserts the method has no body. POST/PUT/PATCH *do* have a body, so a
        // bodiless one (e.g. the PATCH .../stop endpoint) would panic. Send an
        // explicit empty body for those to take the content-length:0 path.
        const effective_payload: ?[]const u8 = payload orelse
            (if (method.requestHasBody()) "" else null);

        const result = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = method,
            .payload = effective_payload,
            // Use a fresh connection per request. Toggl closes idle keep-alive
            // connections, and reusing a stale pooled one yields
            // error.HttpConnectionClosing on the next request in a run (e.g.
            // the several calls `toggl update` makes).
            .keep_alive = false,
            .headers = .{
                .authorization = .{ .override = self.auth_header },
                .user_agent = .{ .override = user_agent },
                // Only advertise JSON when we actually send a JSON body.
                .content_type = if (payload != null)
                    .{ .override = "application/json" }
                else
                    .default,
            },
            .response_writer = &sink.writer,
        });
        return .{ .status = @intFromEnum(result.status), .body = sink.written() };
    }

    /// Make a request and return the body, or an error (after printing the
    /// server's message) on a non-2xx status.
    fn requestChecked(self: *Client, method: std.http.Method, url: []const u8, payload: ?[]const u8) ![]const u8 {
        const res = try self.request(method, url, payload);
        if (!res.ok()) {
            // Status line in red; leave the (possibly large) body uncolored.
            color.eprint("Toggl API error: HTTP {d}\n", .{res.status});
            std.debug.print("{s}\n", .{res.body});
            return error.ApiError;
        }
        return res.body;
    }

    fn buildUrl(self: *Client, comptime fmt: []const u8, args: anytype) ![]const u8 {
        return std.fmt.allocPrint(self.arena, base_url ++ fmt, args);
    }

    fn parse(self: *Client, comptime T: type, body: []const u8) !T {
        return std.json.parseFromSliceLeaky(T, self.arena, body, .{ .ignore_unknown_fields = true });
    }

    /// Parse a list endpoint that may return either a bare JSON array or a
    /// paginated wrapper object (`{"data": [...]}` or `{"items": [...]}`).
    /// Toggl is inconsistent across endpoints, so we handle both.
    fn parseList(self: *Client, comptime T: type, body: []const u8) ![]T {
        const trimmed = std.mem.trimStart(u8, body, " \t\r\n");
        if (trimmed.len > 0 and trimmed[0] == '[') return self.parse([]T, body);
        const Wrapper = struct { data: ?[]T = null, items: ?[]T = null };
        const w = try self.parse(Wrapper, body);
        return w.data orelse w.items orelse &.{};
    }

    fn toJson(self: *Client, value: anytype) ![]const u8 {
        var out: Io.Writer.Allocating = .init(self.arena);
        // Omit null optional fields so we only send what we mean to set.
        try std.json.Stringify.value(value, .{ .emit_null_optional_fields = false }, &out.writer);
        return out.written();
    }

    // ---- typed endpoints --------------------------------------------------

    pub const Me = struct {
        id: i64,
        default_workspace_id: i64 = 0,
        fullname: ?[]const u8 = null,
    };

    pub const TimeEntry = struct {
        id: i64,
        workspace_id: i64 = 0,
        project_id: ?i64 = null,
        task_id: ?i64 = null,
        description: ?[]const u8 = null,
        start: ?[]const u8 = null,
        stop: ?[]const u8 = null,
        duration: i64 = 0,
        tags: ?[]const []const u8 = null,
    };

    pub const Project = struct {
        id: i64,
        name: []const u8 = "",
        client_id: ?i64 = null,
        active: bool = true,
    };

    pub const Task = struct {
        id: i64,
        name: []const u8 = "",
        project_id: i64 = 0,
        active: bool = true,
    };

    pub const ClientInfo = struct {
        id: i64,
        name: []const u8 = "",
    };

    pub fn getMe(self: *Client) !Me {
        const body = try self.requestChecked(.GET, try self.buildUrl("/me", .{}), null);
        return self.parse(Me, body);
    }

    /// Resolve the workspace to operate in, caching the result. Uses the
    /// configured workspace if set, otherwise the account default from /me.
    pub fn workspaceId(self: *Client) !i64 {
        if (self.workspace_id != 0) return self.workspace_id;
        const me = try self.getMe();
        self.workspace_id = me.default_workspace_id;
        return self.workspace_id;
    }

    /// The currently running entry, or null if nothing is running.
    pub fn current(self: *Client) !?TimeEntry {
        const body = try self.requestChecked(.GET, try self.buildUrl("/me/time_entries/current", .{}), null);
        // This endpoint returns the JSON literal `null` when idle.
        return self.parse(?TimeEntry, body);
    }

    /// Recent time entries. With null dates, the API defaults to the last 9
    /// days; pass `start_date`/`end_date` (YYYY-MM-DD or RFC3339) to widen it.
    pub fn list(self: *Client, start_date: ?[]const u8, end_date: ?[]const u8) ![]TimeEntry {
        const url = if (start_date) |sd|
            try std.fmt.allocPrint(self.arena, base_url ++ "/me/time_entries?start_date={s}&end_date={s}", .{ sd, end_date orelse sd })
        else
            try self.buildUrl("/me/time_entries", .{});
        const body = try self.requestChecked(.GET, url, null);
        return self.parse([]TimeEntry, body);
    }

    pub fn listProjects(self: *Client) ![]Project {
        const wid = try self.workspaceId();
        const body = try self.requestChecked(
            .GET,
            try self.buildUrl("/workspaces/{d}/projects?active=true&per_page=200", .{wid}),
            null,
        );
        return self.parseList(Project, body);
    }

    /// Tasks ("sub-projects") are a paid-plan feature. If the workspace can't
    /// access them, degrade gracefully to an empty list rather than erroring.
    pub fn listTasks(self: *Client) ![]Task {
        const wid = try self.workspaceId();
        const res = try self.request(
            .GET,
            try self.buildUrl("/workspaces/{d}/tasks?active=true&per_page=200", .{wid}),
            null,
        );
        if (!res.ok()) return &.{};
        return self.parseList(Task, res.body);
    }

    /// Clients group projects; used only for nicer labels. Optional.
    pub fn listClients(self: *Client) ![]ClientInfo {
        const wid = try self.workspaceId();
        const res = try self.request(.GET, try self.buildUrl("/workspaces/{d}/clients", .{wid}), null);
        if (!res.ok()) return &.{};
        return self.parseList(ClientInfo, res.body);
    }

    pub const StartArgs = struct {
        description: []const u8,
        project_id: ?i64 = null,
        task_id: ?i64 = null,
        tags: ?[]const []const u8 = null,
    };

    pub fn start(self: *Client, args: StartArgs) !TimeEntry {
        const wid = try self.workspaceId();
        var start_buf: [32]u8 = undefined;

        const Body = struct {
            created_with: []const u8 = "toggl-cli",
            description: []const u8,
            workspace_id: i64,
            start: []const u8,
            duration: i64 = -1, // negative duration == running entry
            project_id: ?i64 = null,
            task_id: ?i64 = null,
            tags: ?[]const []const u8 = null,
        };
        const body = try self.toJson(Body{
            .description = args.description,
            .workspace_id = wid,
            .start = try timefmt.nowRfc3339(self.io, &start_buf),
            .project_id = args.project_id,
            .task_id = args.task_id,
            .tags = args.tags,
        });

        const resp = try self.requestChecked(
            .POST,
            try self.buildUrl("/workspaces/{d}/time_entries", .{wid}),
            body,
        );
        return self.parse(TimeEntry, resp);
    }

    pub fn stop(self: *Client, entry_id: i64) !TimeEntry {
        const wid = try self.workspaceId();
        const resp = try self.requestChecked(
            .PATCH,
            try self.buildUrl("/workspaces/{d}/time_entries/{d}/stop", .{ wid, entry_id }),
            null,
        );
        return self.parse(TimeEntry, resp);
    }

    pub const UpdateArgs = struct {
        description: ?[]const u8 = null,
        project_id: ?i64 = null,
        task_id: ?i64 = null,
        tags: ?[]const []const u8 = null,
    };

    pub fn update(self: *Client, entry_id: i64, args: UpdateArgs) !TimeEntry {
        const wid = try self.workspaceId();
        // Only non-null fields are emitted (see toJson), so this is a partial
        // update of just what the caller provided.
        const body = try self.toJson(args);
        const resp = try self.requestChecked(
            .PUT,
            try self.buildUrl("/workspaces/{d}/time_entries/{d}", .{ wid, entry_id }),
            body,
        );
        return self.parse(TimeEntry, resp);
    }

    /// The intended state of an entry's editable fields for the interactive
    /// editor. description/project_id/task_id/tags are always sent (so a task
    /// can be cleared via an explicit null); start/stop/duration are only sent
    /// when non-null, so a normal edit never disturbs the entry's times.
    pub const FullUpdate = struct {
        description: []const u8,
        project_id: ?i64 = null,
        task_id: ?i64 = null,
        tags: []const []const u8 = &.{},
        // Toggl derives stop from start + duration, so we never send `stop`.
        start: ?[]const u8 = null,
        duration: ?i64 = null,
    };

    /// Update an entry in its own workspace (falls back to the default when
    /// `workspace_id` is 0). Used by the interactive editor, which can target
    /// any past entry, not just the running one.
    pub fn updateFields(self: *Client, workspace_id: i64, entry_id: i64, fields: FullUpdate) !TimeEntry {
        const wid = if (workspace_id != 0) workspace_id else try self.workspaceId();

        // Built by hand for precise control: always-present fields use explicit
        // null where meaningful, while start/stop/duration are omitted unless
        // set. std.json.Stringify.value handles the string/array escaping.
        var out: Io.Writer.Allocating = .init(self.arena);
        const w = &out.writer;
        try w.writeAll("{\"description\":");
        try std.json.Stringify.value(fields.description, .{}, w);
        try w.writeAll(",\"project_id\":");
        if (fields.project_id) |p| try w.print("{d}", .{p}) else try w.writeAll("null");
        try w.writeAll(",\"task_id\":");
        if (fields.task_id) |t| try w.print("{d}", .{t}) else try w.writeAll("null");
        try w.writeAll(",\"tags\":");
        try std.json.Stringify.value(fields.tags, .{}, w);
        if (fields.start) |s| {
            try w.writeAll(",\"start\":");
            try std.json.Stringify.value(s, .{}, w);
        }
        if (fields.duration) |d| try w.print(",\"duration\":{d}", .{d});
        try w.writeAll("}");

        const resp = try self.requestChecked(
            .PUT,
            try self.buildUrl("/workspaces/{d}/time_entries/{d}", .{ wid, entry_id }),
            out.written(),
        );
        return self.parse(TimeEntry, resp);
    }
};
