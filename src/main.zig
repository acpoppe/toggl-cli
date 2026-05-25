const std = @import("std");
const Io = std.Io;

const config = @import("config.zig");
const api = @import("api.zig");
const timefmt = @import("timefmt.zig");
const cache = @import("cache.zig");
const picker = @import("picker.zig");
const localtz = @import("localtz.zig");
const color = @import("color.zig");
const build_options = @import("build_options");

const usage =
    \\toggl - control Toggl Track time entries from the command line
    \\
    \\Usage:
    \\  toggl auth <api_token>             Save your API token + default workspace
    \\  toggl start <description> [opts]   Start a new running time entry
    \\  toggl resume                       Resume the most recent entry (confirms first)
    \\  toggl stop                         Stop the currently running entry
    \\  toggl status                       Show the currently running entry
    \\  toggl update [opts]                Edit an entry (interactive, or running with flags)
    \\  toggl list [count]                 List recent entries (default 10)
    \\  toggl sync                         Refresh the cached project/task list
    \\  toggl version                      Print the version (also --version)
    \\
    \\Options (for start / update):
    \\  -p, --project <id|name>  Project id, or name to match (opens a picker
    \\                           when ambiguous; start opens it when omitted)
    \\  -t, --tag <tag>          Tag (repeatable)
    \\  -d, --description <s>    Description (mainly for `update`)
    \\
    \\Run `toggl help <command>` or `toggl <command> --help` for command details.
    \\
    \\The API token is read from $TOGGL_API_TOKEN if set, otherwise from the
    \\config file (~/.config/toggl-cli/config.json) written by `toggl auth`.
    \\
;

// Per-command help, shown by `toggl help <cmd>` or `toggl <cmd> -h|--help`.

const help_auth =
    \\toggl auth <api_token>
    \\
    \\Validate an API token and save it, along with your default workspace, to
    \\~/.config/toggl-cli/config.json. Run this once before the other commands
    \\(unless you set $TOGGL_API_TOKEN instead).
    \\
    \\Find your token in Toggl Track under Profile settings -> API Token.
    \\
    \\Example:
    \\  toggl auth 1234567890abcdef1234567890abcdef
    \\
;

const help_start =
    \\toggl start <description> [options]
    \\
    \\Start a new running time entry. The description may be a single quoted
    \\argument or several bare words (they are joined with spaces).
    \\
    \\Project selection:
    \\  -p, --project <id|name>  Use a project id directly, or a name fragment.
    \\                           A unique name match is used as-is; otherwise an
    \\                           interactive picker opens, pre-filtered.
    \\  If you omit -p entirely, the picker opens automatically (Esc = no
    \\  project). "Sub-projects" (Toggl tasks) appear as "Project / Task" rows.
    \\  The list is cached locally; run `toggl sync` to refresh it.
    \\
    \\Other options:
    \\  -t, --tag <tag>          Add a tag (repeatable)
    \\  -d, --description <s>    Set the description explicitly
    \\
    \\Examples:
    \\  toggl start "fixing the build"          # picker opens for the project
    \\  toggl start writing docs -p backend     # match project by name
    \\  toggl start review -p 12345 -t urgent   # explicit project id
    \\
;

const help_resume =
    \\toggl resume        (alias: continue)
    \\
    \\Resume your most recent time entry. It shows that entry and asks for
    \\confirmation, then starts a new running entry copying its description,
    \\project, task, and tags (with a fresh start time). Refuses if an entry is
    \\already running — stop it first with `toggl stop`.
    \\
    \\Toggl has no dedicated resume endpoint; this mirrors the web app's
    \\"Continue", which simply creates a new entry from the last one.
    \\
;

const help_stop =
    \\toggl stop
    \\
    \\Stop the currently running time entry. Prints nothing-is-running if the
    \\timer is already idle.
    \\
;

const help_status =
    \\toggl status        (alias: current)
    \\
    \\Show the currently running time entry: description, id, project, elapsed
    \\time, and tags. Reports when nothing is running.
    \\
;

const help_update =
    \\toggl update [options]
    \\
    \\With no options, opens an interactive editor: first pick which entry to
    \\edit (the running one, or any recent entry) from a fuzzy list, then a menu
    \\lets you change its description, project, tags, or start/stop time, and
    \\Save applies them. Times accept a relative offset like -15m or +1h30m
    \\(handy when you forgot to start), or an absolute local "YYYY-MM-DD HH:MM".
    \\Times are shown in your system timezone.
    \\
    \\With options, it updates the running entry directly (no prompts). Only the
    \\fields you pass are changed.
    \\
    \\Options:
    \\  -d, --description <s>    New description (a bare argument also works)
    \\  -p, --project <id|name>  Set the project (id, name match, or picker)
    \\  -t, --tag <tag>          Add a tag (repeatable)
    \\
    \\Examples:
    \\  toggl update                 # interactive: choose an entry, then edit
    \\  toggl update -d "renamed task"
    \\  toggl update -p backend
    \\  toggl update -p 12345 -t urgent
    \\
;

const help_list =
    \\toggl list [count]          (alias: ls)
    \\
    \\List your recent time entries, most recent first. `count` is how many to
    \\show (default 10), e.g. `toggl list 25`.
    \\
    \\To find enough entries, it looks back roughly one day per requested entry
    \\(at least 9 days). The Toggl API only serves the last ~90 days here, so
    \\that's the furthest back it can reach; at most 1000 entries are fetched.
    \\
;

const help_sync =
    \\toggl sync
    \\
    \\Fetch your workspace's projects and tasks ("sub-projects") and cache them
    \\locally (~/.config/toggl-cli/cache.json) for the interactive picker. The
    \\cache auto-refreshes once a day; run this to force an update sooner.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const env = init.environ_map;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_fw.interface;

    // Decide once whether to colorize, based on each stream + the environment.
    color.detect(io, Io.File.stdout(), env);
    color.detectErr(io, Io.File.stderr(), env);

    run(arena, io, env, out, args) catch |err| {
        // Domain errors already printed a helpful message; anything else is
        // unexpected, so surface it.
        switch (err) {
            error.ApiError, error.NoToken, error.Usage, error.AlreadyRunning => {},
            else => color.eprint("error: {s}\n", .{@errorName(err)}),
        }
        out.flush() catch {};
        std.process.exit(1);
    };
    try out.flush();
}

fn run(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    args: []const [:0]const u8,
) !void {
    if (args.len < 2) {
        try out.writeAll(usage);
        return;
    }

    const cmd = args[1];
    const rest = args[2..];

    if (eql(cmd, "version") or eql(cmd, "--version") or eql(cmd, "-v")) {
        try color.on(out, .bold);
        try out.print("toggl {s}", .{build_options.version});
        try color.off(out);
        try out.writeByte('\n');
        return;
    }

    // `toggl help`, `toggl help <command>`, and bare `-h`/`--help`.
    if (eql(cmd, "help") or eql(cmd, "-h") or eql(cmd, "--help")) {
        if (rest.len == 0) {
            try out.writeAll(usage);
        } else if (commandHelp(rest[0])) |h| {
            try out.writeAll(h);
        } else {
            color.eprint("unknown command: {s}\n\n", .{rest[0]});
            try out.writeAll(usage);
            return error.Usage;
        }
        return;
    }

    // `toggl <command> -h|--help` shows that command's help instead of running.
    if (wantsHelp(rest)) {
        if (commandHelp(cmd)) |h| {
            try out.writeAll(h);
            return;
        }
        // Unknown command with --help: fall through to the unknown-command path.
    }

    if (eql(cmd, "auth")) {
        try cmdAuth(arena, io, env, out, rest);
    } else if (eql(cmd, "start")) {
        try cmdStart(arena, io, env, out, rest);
    } else if (eql(cmd, "resume") or eql(cmd, "continue")) {
        try cmdResume(arena, io, env, out);
    } else if (eql(cmd, "stop")) {
        try cmdStop(arena, io, env, out);
    } else if (eql(cmd, "status") or eql(cmd, "current")) {
        try cmdStatus(arena, io, env, out);
    } else if (eql(cmd, "update")) {
        try cmdUpdate(arena, io, env, out, rest);
    } else if (eql(cmd, "list") or eql(cmd, "ls")) {
        try cmdList(arena, io, env, out, rest);
    } else if (eql(cmd, "sync")) {
        try cmdSync(arena, io, env, out);
    } else if (eql(cmd, "pickdemo")) {
        try cmdPickDemo(arena, io, out);
    } else if (eql(cmd, "editdemo")) {
        try cmdEditDemo(arena, io, out);
    } else {
        color.eprint("unknown command: {s}\n\n", .{cmd});
        try out.writeAll(usage);
        return error.Usage;
    }
}

/// Detailed help text for a command name (including its aliases), or null if
/// the name isn't a known command.
fn commandHelp(cmd: []const u8) ?[]const u8 {
    if (eql(cmd, "auth")) return help_auth;
    if (eql(cmd, "start")) return help_start;
    if (eql(cmd, "resume") or eql(cmd, "continue")) return help_resume;
    if (eql(cmd, "stop")) return help_stop;
    if (eql(cmd, "status") or eql(cmd, "current")) return help_status;
    if (eql(cmd, "update")) return help_update;
    if (eql(cmd, "list") or eql(cmd, "ls")) return help_list;
    if (eql(cmd, "sync")) return help_sync;
    return null;
}

/// True if any argument is a help flag (`-h` / `--help`).
fn wantsHelp(args: []const [:0]const u8) bool {
    for (args) |a| {
        if (eql(a, "-h") or eql(a, "--help")) return true;
    }
    return false;
}

// ---- commands -------------------------------------------------------------

fn cmdAuth(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    rest: []const [:0]const u8,
) !void {
    if (rest.len < 1) {
        color.eprint("usage: toggl auth <api_token>\n", .{});
        return error.Usage;
    }
    const token = rest[0];

    var client = try api.Client.init(arena, io, token);
    defer client.deinit();

    // Validate the token and grab the default workspace in one call.
    const me = try client.getMe();

    try config.save(arena, io, env, .{
        .api_token = token,
        .workspace_id = me.default_workspace_id,
    });

    const who = me.fullname orelse "your account";
    try color.on(out, .green);
    try out.print("Authenticated as {s}.", .{who});
    try color.off(out);
    try out.writeByte('\n');
    try color.on(out, .gray);
    try out.print("Default workspace: {d}\n", .{me.default_workspace_id});
    try out.print("Saved to {s}\n", .{config.displayPath(arena, env)});
    try color.off(out);
}

/// Refuse (red error + error.AlreadyRunning) if an entry is already running.
/// Shared by `start` and `resume`, both of which create a new running entry.
fn ensureNothingRunning(io: Io, client: *api.Client) !void {
    const running = try client.current() orelse return;
    const rdesc: []const u8 = if (running.description) |d|
        (if (d.len > 0) d else "(no description)")
    else
        "(no description)";
    const started: ?i64 = if (running.start) |s| timefmt.parseRfc3339(s) else null;
    // u64 so `{d:0>2}` zero-pads without Zig emitting a `+` sign on signed ints.
    const elapsed: u64 = @intCast(if (started) |se| @max(0, timefmt.nowUnix(io) - se) else 0);
    color.eprint(
        "An entry is already running: \"{s}\" ({d}h {d:0>2}m).\nStop it first with `toggl stop`.\n",
        .{ rdesc, elapsed / 3600, (elapsed % 3600) / 60 },
    );
    return error.AlreadyRunning;
}

fn cmdStart(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    rest: []const [:0]const u8,
) !void {
    var opts = try parseOpts(arena, rest);

    const description = opts.description orelse blk: {
        if (opts.positionals.items.len == 0) {
            color.eprint("usage: toggl start <description> [-p <project>] [-t <tag>]...\n", .{});
            return error.Usage;
        }
        break :blk try std.mem.join(arena, " ", opts.positionals.items);
    };

    var client = try makeClient(arena, io, env);
    defer client.deinit();

    // Refuse to silently replace a running entry — Toggl would auto-stop it.
    try ensureNothingRunning(io, &client);

    // start always tries to resolve a project: explicit id/name, else picker.
    const proj = try resolveProject(arena, io, env, &client, opts);

    const entry = try client.start(.{
        .description = description,
        .project_id = if (proj) |p| p.project_id else null,
        .task_id = if (proj) |p| p.task_id else null,
        .tags = opts.tagsSlice(),
    });

    const labels = loadLabels(arena, io, env);
    const zone = localtz.load(arena, io);
    try header(out, .green, "Started:");
    try printEntry(io, out, entry, labels, zone);
}

/// Resume the most recent entry: show it, confirm, then start a fresh running
/// entry copying its description/project/task/tags. Toggl has no resume
/// endpoint, so (like the web app's "Continue") this just creates a new entry.
fn cmdResume(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
) !void {
    var client = try makeClient(arena, io, env);
    defer client.deinit();

    try ensureNothingRunning(io, &client);

    const recent = try client.list(null, null);
    if (recent.len == 0) {
        try color.write(out, .dim, "No recent entry to resume.\n");
        return;
    }
    // Most recent by start time (none are running — that's guarded above).
    var latest = recent[0];
    for (recent[1..]) |e| {
        const a = if (latest.start) |s| timefmt.parseRfc3339(s) orelse 0 else 0;
        const b = if (e.start) |s| timefmt.parseRfc3339(s) orelse 0 else 0;
        if (b > a) latest = e;
    }

    const labels = loadLabels(arena, io, env);
    const zone = localtz.load(arena, io);

    try header(out, .cyan, "Most recent entry:");
    try printEntry(io, out, latest, labels, zone);
    try out.flush();

    const ok = try picker.confirm(io, "Resume this entry? [y/N] ");
    if (!(ok orelse false)) {
        try color.write(out, .dim, "Not resumed.\n");
        return;
    }

    const entry = try client.start(.{
        .description = latest.description orelse "",
        .project_id = latest.project_id,
        .task_id = latest.task_id,
        .tags = latest.tags,
    });
    try header(out, .green, "Resumed:");
    try printEntry(io, out, entry, labels, zone);
}

fn cmdStop(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
) !void {
    var client = try makeClient(arena, io, env);
    defer client.deinit();

    const running = try client.current() orelse {
        try color.write(out, .dim, "Nothing is running.\n");
        return;
    };

    const stopped = try client.stop(running.id);
    const labels = loadLabels(arena, io, env);
    const zone = localtz.load(arena, io);
    try header(out, .red, "Stopped:");
    try printEntry(io, out, stopped, labels, zone);
}

fn cmdStatus(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
) !void {
    var client = try makeClient(arena, io, env);
    defer client.deinit();

    const running = try client.current() orelse {
        try color.write(out, .dim, "Nothing is running.\n");
        return;
    };

    const labels = loadLabels(arena, io, env);
    const zone = localtz.load(arena, io);
    try header(out, .green, "Running:");
    try printEntry(io, out, running, labels, zone);
}

fn cmdUpdate(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    rest: []const [:0]const u8,
) !void {
    var opts = try parseOpts(arena, rest);
    // Allow a bare positional as the new description too.
    const description = opts.description orelse
        if (opts.positionals.items.len > 0)
            try std.mem.join(arena, " ", opts.positionals.items)
        else
            null;

    const touches_project = opts.project_id != null or opts.project_query != null;
    const has_flags = description != null or touches_project or opts.tagsSlice() != null;

    var client = try makeClient(arena, io, env);
    defer client.deinit();

    // No flags -> interactive editor (lets you pick any entry, not just the
    // running one). Flags -> non-interactive update of the running entry.
    if (!has_flags) {
        return interactiveUpdate(arena, io, env, &client, out);
    }

    const running = try client.current() orelse {
        try color.write(out, .dim, "Nothing is running. Run `toggl update` with no flags to pick a past entry.\n");
        return;
    };

    const proj = if (touches_project) try resolveProject(arena, io, env, &client, opts) else null;

    const updated = try client.update(running.id, .{
        .description = description,
        .project_id = if (proj) |p| p.project_id else null,
        .task_id = if (proj) |p| p.task_id else null,
        .tags = opts.tagsSlice(),
    });
    const labels = loadLabels(arena, io, env);
    const zone = localtz.load(arena, io);
    try header(out, .yellow, "Updated:");
    try printEntry(io, out, updated, labels, zone);
}

/// Interactive update: choose an entry (running or recent), then edit its
/// fields via a menu, then save.
fn interactiveUpdate(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    client: *api.Client,
    out: *Io.Writer,
) !void {
    // Project/task list — drives both the labels and the project sub-picker.
    const projects = try ensureCache(arena, io, env, client);
    const zone = localtz.load(arena, io);

    // Build the chooser: running entry first (if any), then recent ones.
    const recent = try client.list(null, null);
    const running = client.current() catch null;

    var entries: std.ArrayList(api.Client.TimeEntry) = .empty;
    if (running) |r| try entries.append(arena, r);
    for (recent) |e| {
        if (running) |r| if (r.id == e.id) continue;
        try entries.append(arena, e);
    }
    if (entries.items.len == 0) {
        try color.write(out, .dim, "No entries to edit.\n");
        return;
    }

    const labels = try arena.alloc([]const u8, entries.items.len);
    for (entries.items, 0..) |e, i| labels[i] = try entryLabel(arena, io, e, projects, zone);

    const idx = try picker.pickIndex(arena, io, labels, .{
        .title = "Pick an entry to edit — type to filter, ^J/^K or arrows move, Enter select, Esc cancel",
        .show_filter = true,
    }) orelse {
        try color.write(out, .dim, "Cancelled.\n");
        return;
    };

    try editEntry(arena, io, out, client, entries.items[idx], projects, zone);
}

/// The field-menu editor for a single entry. `client` is optional: when null
/// (demo mode) Save just prints the pending values instead of calling the API.
fn editEntry(
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    client: ?*api.Client,
    entry: api.Client.TimeEntry,
    projects: []const cache.Entry,
    zone: localtz.Zone,
) !void {
    const running = entry.duration < 0;

    var desc: []const u8 = entry.description orelse "";
    var project_id: ?i64 = entry.project_id;
    var task_id: ?i64 = entry.task_id;
    var start_epoch: ?i64 = if (entry.start) |s| timefmt.parseRfc3339(s) else null;
    var stop_epoch: ?i64 = if (entry.stop) |s| timefmt.parseRfc3339(s) else null;
    var time_changed = false;

    var tags: std.ArrayList([]const u8) = .empty;
    if (entry.tags) |ts| for (ts) |t| try tags.append(arena, t);

    const Action = enum { description, project, tags, start, stop, save, cancel };

    while (true) {
        const proj_disp = if (project_id) |pid|
            (lookupLabel(projects, pid, task_id) orelse "(unknown)")
        else
            "(none)";
        const tags_disp = if (tags.items.len == 0) "(none)" else try std.mem.join(arena, ", ", tags.items);

        var labels: std.ArrayList([]const u8) = .empty;
        var actions: std.ArrayList(Action) = .empty;
        try labels.append(arena, if (desc.len == 0)
            try fieldRowMissing(arena, "Description:  ", "(empty)")
        else
            try fieldRow(arena, "Description:  ", desc, .bold));
        try actions.append(arena, .description);
        try labels.append(arena, if (project_id == null)
            try fieldRowMissing(arena, "Project:      ", "(none)")
        else
            try fieldRow(arena, "Project:      ", proj_disp, .cyan));
        try actions.append(arena, .project);
        try labels.append(arena, try fieldRow(arena, "Tags:         ", tags_disp, .yellow));
        try actions.append(arena, .tags);
        try labels.append(arena, try fieldRow(arena, "Start time:   ", try fmtStart(arena, io, zone, start_epoch, running), null));
        try actions.append(arena, .start);
        if (!running) {
            try labels.append(arena, try fieldRow(arena, "Stop time:    ", try fmtInstant(arena, zone, stop_epoch), null));
            try actions.append(arena, .stop);
        }
        try labels.append(arena, try styled(arena, .green, "Save changes"));
        try actions.append(arena, .save);
        try labels.append(arena, try styled(arena, .dim, "Cancel"));
        try actions.append(arena, .cancel);

        const choice = try picker.pickIndex(arena, io, labels.items, .{
            .title = "Editing entry — j/k or arrows move, Enter select, Esc cancel",
            .show_filter = false,
        }) orelse {
            try color.write(out, .dim, "No changes saved.\n");
            return;
        };

        switch (actions.items[choice]) {
            .description => {
                if (try picker.readLine(arena, io, "Description: ", desc)) |d| desc = d;
            },
            .project => { // Esc in the sub-picker keeps the current project
                if (projects.len > 0) {
                    const plabels = try arena.alloc([]const u8, projects.len);
                    for (projects, 0..) |p, i| plabels[i] = try styled(arena, .cyan, p.label);
                    if (try picker.pickIndex(arena, io, plabels, .{
                        .title = "Pick a project — type to filter, ^J/^K or arrows move, Enter select, Esc keep",
                        .show_filter = true,
                    })) |pi| {
                        project_id = projects[pi].project_id;
                        task_id = projects[pi].task_id;
                    }
                }
            },
            .tags => {
                const joined = try std.mem.join(arena, ", ", tags.items);
                if (try picker.readLine(arena, io, "Tags (comma-separated): ", joined)) |line| {
                    tags.clearRetainingCapacity();
                    var it = std.mem.tokenizeScalar(u8, line, ',');
                    while (it.next()) |part| {
                        const t = std.mem.trim(u8, part, " \t");
                        if (t.len > 0) try tags.append(arena, t);
                    }
                }
            },
            .start => {
                if (try editTime(arena, io, out, zone, "start", start_epoch)) |ne| {
                    start_epoch = ne;
                    time_changed = true;
                }
            },
            .stop => {
                if (try editTime(arena, io, out, zone, "stop", stop_epoch)) |ne| {
                    stop_epoch = ne;
                    time_changed = true;
                }
            },
            .save => {
                var fields: api.Client.FullUpdate = .{
                    .description = desc,
                    .project_id = project_id,
                    .task_id = task_id,
                    .tags = tags.items,
                };
                if (time_changed) {
                    if (start_epoch) |se| fields.start = try timefmt.epochToRfc3339Alloc(arena, se);
                    // Toggl derives stop = start + duration, so we send duration
                    // only. Sending `stop` as well triggers a "Stop and duration
                    // mismatch" 400, so we never send it.
                    if (running) {
                        fields.duration = -1; // keep it running from the new start
                    } else if (start_epoch) |se| {
                        if (stop_epoch) |pe| {
                            if (pe <= se) {
                                try color.write(out, .red, "Stop must be after start — adjust the times and try again.\n");
                                try out.flush();
                                continue; // keep edits, back to the menu
                            }
                            fields.duration = pe - se;
                        }
                    }
                }

                if (client) |c| {
                    const updated = try c.updateFields(entry.workspace_id, entry.id, fields);
                    try header(out, .yellow, "Updated:");
                    try printEntry(io, out, updated, projects, zone);
                } else {
                    try header(out, .cyan, "Would save (demo):");
                    try color.write(out, .gray, "  description: ");
                    try color.write(out, .bold, desc);
                    try out.writeByte('\n');
                    try color.write(out, .gray, "  project: ");
                    try color.write(out, .cyan, proj_disp);
                    try out.writeByte('\n');
                    try color.write(out, .gray, "  tags: ");
                    try color.write(out, .yellow, tags_disp);
                    try out.writeByte('\n');
                    if (fields.start) |s| {
                        try color.write(out, .gray, "  start: ");
                        try out.print("{s}\n", .{s});
                    }
                    if (fields.duration) |d| {
                        try color.write(out, .gray, "  duration: ");
                        try out.print("{d}\n", .{d});
                    }
                }
                return;
            },
            .cancel => {
                try color.write(out, .dim, "No changes saved.\n");
                return;
            },
        }
    }
}

/// Prompt for a new start/stop time and return the new epoch (UTC), or null to
/// keep the current value. Accepts a relative offset (-15m, +1h30m) applied to
/// the current value, or an absolute *local* time (YYYY-MM-DD HH:MM, or HH:MM
/// today) which is converted to UTC for the API.
fn editTime(arena: std.mem.Allocator, io: Io, out: *Io.Writer, zone: localtz.Zone, which: []const u8, current: ?i64) !?i64 {
    // Use the field's current value (in local time, "YYYY-MM-DD HH:MM") as the
    // absolute-format example, so it shows both the format and where it's at now.
    const example: []const u8 = if (current) |c| ex: {
        var buf: [32]u8 = undefined;
        const rfc = try timefmt.epochToRfc3339(c + zone.offsetAt(c), &buf);
        const part = try arena.dupe(u8, rfc[0..16]); // "YYYY-MM-DDTHH:MM"
        part[10] = ' ';
        break :ex part;
    } else "2026-05-24 14:30";

    const prompt = try std.fmt.allocPrint(
        arena,
        "New {s} (-15m, +1h30m, or {s}): ",
        .{ which, example },
    );
    const line = (try picker.readLine(arena, io, prompt, "")) orelse return null;
    const s = std.mem.trim(u8, line, " \t");
    if (s.len == 0) return null;

    if (s[0] == '+' or s[0] == '-') {
        const base = current orelse {
            try color.write(out, .red, "Can't read the current time to offset from.\n");
            return null;
        };
        const off = parseOffsetSeconds(s) orelse {
            try color.on(out, .red);
            try out.print("Couldn't parse offset '{s}'.", .{s});
            try color.off(out);
            try out.writeByte('\n');
            return null;
        };
        return base + off;
    }

    return parseAbsoluteLocal(io, zone, s) orelse {
        try color.on(out, .red);
        try out.print("Couldn't parse time '{s}'.", .{s});
        try color.off(out);
        try out.writeByte('\n');
        return null;
    };
}

/// Parse "+1h30m" / "-15m" / "-90" (bare number = minutes) into signed seconds.
fn parseOffsetSeconds(s: []const u8) ?i64 {
    if (s.len < 2) return null;
    const sign: i64 = switch (s[0]) {
        '+' => 1,
        '-' => -1,
        else => return null,
    };
    var total: i64 = 0;
    var num: i64 = 0;
    var saw_unit = false;
    var saw_digit = false;
    for (s[1..]) |c| {
        switch (c) {
            '0'...'9' => {
                num = num * 10 + (c - '0');
                saw_digit = true;
            },
            'h', 'H' => {
                total += num * 3600;
                num = 0;
                saw_unit = true;
            },
            'm', 'M' => {
                total += num * 60;
                num = 0;
                saw_unit = true;
            },
            's', 'S' => {
                total += num;
                num = 0;
                saw_unit = true;
            },
            ' ' => {},
            else => return null,
        }
    }
    if (!saw_digit) return null;
    // A bare trailing number means minutes (so "-90" and "-1h30" both work).
    total += if (saw_unit) num * 60 else num * 60;
    return sign * total;
}

/// Parse an absolute *local* time and return the UTC epoch. Accepts
/// "YYYY-MM-DD HH:MM[:SS]" or "HH:MM" (today, local). The entered wall time is
/// converted to UTC using the zone's offset at that instant.
fn parseAbsoluteLocal(io: Io, zone: localtz.Zone, s: []const u8) ?i64 {
    const wall: i64 = blk: {
        // Full date-time.
        if (s.len >= 16 and s[4] == '-' and s[7] == '-') {
            const y = pInt(s[0..4]) orelse return null;
            const mo = pInt(s[5..7]) orelse return null;
            const d = pInt(s[8..10]) orelse return null;
            const h = pInt(s[11..13]) orelse return null;
            const mi = pInt(s[14..16]) orelse return null;
            const se: i64 = if (s.len >= 19 and s[16] == ':') (pInt(s[17..19]) orelse 0) else 0;
            break :blk timefmt.civilToEpoch(y, mo, d, h, mi, se);
        }
        // Clock time today (local).
        if (std.mem.indexOfScalar(u8, s, ':')) |c| {
            const h = pInt(s[0..c]) orelse return null;
            const mi = pInt(s[c + 1 ..]) orelse return null;
            const now = timefmt.nowUnix(io);
            const now_local = now + zone.offsetAt(now);
            const day_local = @divFloor(now_local, 86400);
            break :blk day_local * 86400 + h * 3600 + mi * 60;
        }
        return null;
    };
    // `wall` is the local wall-clock as if it were UTC; subtract the offset at
    // that instant to get the true UTC epoch.
    return wall - zone.offsetAt(wall);
}

fn pInt(s: []const u8) ?i64 {
    return std.fmt.parseInt(i64, s, 10) catch null;
}

/// Local "YYYY-MM-DD HH:MM ABBR", or "(unknown)" if epoch is null.
fn fmtInstant(arena: std.mem.Allocator, zone: localtz.Zone, epoch: ?i64) ![]const u8 {
    const e = epoch orelse return "(unknown)";
    return localtz.fmtLocal(arena, zone, e);
}

/// Start display: for a running entry, append how long ago it started.
fn fmtStart(arena: std.mem.Allocator, io: Io, zone: localtz.Zone, epoch: ?i64, running: bool) ![]const u8 {
    const e = epoch orelse return "(unknown)";
    const inst = try localtz.fmtLocal(arena, zone, e);
    if (!running) return inst;
    const diff = timefmt.nowUnix(io) - e;
    const mins = if (diff < 0) 0 else @divTrunc(diff, 60);
    if (mins < 60) return std.fmt.allocPrint(arena, "{s}  ({d}m ago)", .{ inst, mins });
    return std.fmt.allocPrint(arena, "{s}  ({d}h{d:0>2}m ago)", .{ inst, @divTrunc(mins, 60), @mod(mins, 60) });
}

/// A one-line, colored description of a time entry for the chooser list.
fn entryLabel(arena: std.mem.Allocator, io: Io, e: api.Client.TimeEntry, projects: []const cache.Entry, zone: localtz.Zone) ![]const u8 {
    // A non-empty description / resolvable project name, or null when missing.
    const desc: ?[]const u8 = if (e.description) |d| (if (d.len > 0) d else null) else null;
    const proj: ?[]const u8 = if (e.project_id) |pid| lookupLabel(projects, pid, e.task_id) else null;

    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;

    if (e.duration < 0) {
        const start_epoch: ?i64 = if (e.start) |s| timefmt.parseRfc3339(s) else null;
        const elapsed = if (start_epoch) |se| timefmt.nowUnix(io) - se else timefmt.nowUnix(io) + e.duration;
        const mins = @divTrunc(if (elapsed < 0) 0 else elapsed, 60);
        try color.write(w, .green, "* ");
        try writeDescProj(w, desc, proj);
        try color.on(w, .green);
        try w.print(" — running {d}m", .{mins});
        try color.off(w);
        return out.written();
    }

    const when = if (e.start) |s|
        (if (timefmt.parseRfc3339(s)) |se| try localtz.fmtLocal(arena, zone, se) else "")
    else
        "";
    try w.writeAll("  ");
    try writeDescProj(w, desc, proj);
    try color.write(w, .gray, " — ");
    try color.write(w, .gray, when);
    return out.written();
}

/// Write "<desc> — <project>" for a chooser row: bold description / cyan
/// project, or the short red placeholders when either is missing.
fn writeDescProj(w: *Io.Writer, desc: ?[]const u8, proj: ?[]const u8) !void {
    if (desc) |d| try color.write(w, .bold, d) else try missing(w, "(no description)");
    try color.write(w, .gray, " — ");
    if (proj) |p| try color.write(w, .cyan, p) else try missing(w, "(no project)");
}

/// Build an arena-owned string of `text` in `style` (plain when color is off).
fn styled(arena: std.mem.Allocator, style: color.Style, text: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    try color.write(&out.writer, style, text);
    return out.written();
}

/// Build a "<label><value>" editor-menu row: gray label, optionally styled
/// value (null = leave the value uncolored).
fn fieldRow(arena: std.mem.Allocator, label: []const u8, value: []const u8, value_style: ?color.Style) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try color.write(w, .gray, label);
    if (value_style) |s| try color.write(w, s, value) else try w.writeAll(value);
    return out.written();
}

fn cmdList(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    rest: []const [:0]const u8,
) !void {
    const count: usize = if (rest.len > 0)
        std.fmt.parseInt(usize, rest[0], 10) catch {
            color.eprint("usage: toggl list [count]\n", .{});
            return error.Usage;
        }
    else
        10;

    var client = try makeClient(arena, io, env);
    defer client.deinit();

    // Look back far enough to likely contain `count` entries (the API defaults
    // to 9 days; we widen ~a day per requested entry). Capped at 89 days because
    // /me/time_entries refuses a start_date older than ~90 days.
    const lookback_days = std.math.clamp(@as(i64, @intCast(count)), 9, 89);
    const now = timefmt.nowUnix(io);
    const start_date = try dateOnly(arena, now - lookback_days * 86400);
    const end_date = try dateOnly(arena, now + 86400); // through end of today

    const entries = try client.list(start_date, end_date);
    if (entries.len == 0) {
        try color.write(out, .dim, "No recent entries.\n");
        return;
    }

    // Most recent first.
    std.mem.sort(api.Client.TimeEntry, entries, {}, struct {
        fn desc(_: void, a: api.Client.TimeEntry, b: api.Client.TimeEntry) bool {
            const ea = if (a.start) |s| timefmt.parseRfc3339(s) orelse 0 else 0;
            const eb = if (b.start) |s| timefmt.parseRfc3339(s) orelse 0 else 0;
            return ea > eb;
        }
    }.desc);

    const labels = loadLabels(arena, io, env);
    const zone = localtz.load(arena, io);
    const shown = entries[0..@min(count, entries.len)];
    try color.on(out, .bold);
    try color.on(out, .cyan);
    try out.print("Recent entries (showing {d} of {d}):", .{ shown.len, entries.len });
    try color.off(out);
    try out.writeByte('\n');
    const cols = color.width(Io.File.stdout()) orelse 48;
    for (shown, 0..) |entry, i| {
        if (i != 0) try divider(out, cols);
        try printEntry(io, out, entry, labels, zone);
    }
}

/// "YYYY-MM-DD" (UTC) for a Unix timestamp, for the list date-range query.
fn dateOnly(arena: std.mem.Allocator, epoch: i64) ![]const u8 {
    var buf: [32]u8 = undefined;
    const rfc = try timefmt.epochToRfc3339(epoch, &buf);
    return arena.dupe(u8, rfc[0..10]);
}

fn cmdSync(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
) !void {
    var client = try makeClient(arena, io, env);
    defer client.deinit();

    const entries = try cache.build(arena, &client);
    try cache.save(arena, io, env, .{ .synced_at = timefmt.nowUnix(io), .entries = entries });
    try color.on(out, .green);
    try out.print("Synced {d} project/task entries.", .{entries.len});
    try color.off(out);
    try out.writeByte('\n');
}

/// Sample project/task entries for the offline demo commands.
const demo_projects = [_]cache.Entry{
    .{ .label = "Acme / Backend", .project_id = 1 },
    .{ .label = "Acme / Backend / Auth rework", .project_id = 1, .task_id = 101 },
    .{ .label = "Acme / Backend / Billing service", .project_id = 1, .task_id = 102 },
    .{ .label = "Acme / Backend / Rate limiting", .project_id = 1, .task_id = 103 },
    .{ .label = "Acme / Website", .project_id = 2 },
    .{ .label = "Acme / Website / SEO", .project_id = 2, .task_id = 201 },
    .{ .label = "Acme / Website / Checkout redesign", .project_id = 2, .task_id = 202 },
    .{ .label = "Globex / Data pipeline", .project_id = 3 },
    .{ .label = "Globex / Data pipeline / Ingestion", .project_id = 3, .task_id = 301 },
    .{ .label = "Globex / Data pipeline / Dashboards", .project_id = 3, .task_id = 302 },
    .{ .label = "Globex / Mobile app", .project_id = 4 },
    .{ .label = "Initech / TPS reports", .project_id = 5 },
    .{ .label = "Initech / Migration", .project_id = 6 },
    .{ .label = "Initech / Migration / Schema", .project_id = 6, .task_id = 601 },
    .{ .label = "Internal / Meetings", .project_id = 7 },
    .{ .label = "Internal / Code review", .project_id = 8 },
    .{ .label = "Internal / Learning Zig", .project_id = 9 },
};

/// Hidden command: run the project picker over sample data so the TUI can be
/// tried without authentication or network.
fn cmdPickDemo(arena: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    const choice = try picker.pick(arena, io, &demo_projects, "");
    if (choice) |c| {
        try color.on(out, .green);
        try out.print("Selected: {s}  (project_id={d}, task_id={?d})", .{ c.label, c.project_id, c.task_id });
        try color.off(out);
        try out.writeByte('\n');
    } else {
        try color.write(out, .dim, "No selection (cancelled or no terminal).\n");
    }
}

/// Hidden command: run the interactive entry editor (field menu + line editor)
/// over a fake entry, with no auth/network. Save prints the pending values.
fn cmdEditDemo(arena: std.mem.Allocator, io: Io, out: *Io.Writer) !void {
    const tags = [_][]const u8{"deep-work"};
    const entry = api.Client.TimeEntry{
        .id = 999,
        .workspace_id = 1,
        .project_id = 1,
        .task_id = 101,
        .description = "writing docs",
        .start = try timefmt.epochToRfc3339Alloc(arena, timefmt.nowUnix(io) - 2700), // started ~45m ago
        .duration = -1, // running
        .tags = &tags,
    };
    try editEntry(arena, io, out, null, entry, &demo_projects, localtz.load(arena, io));
}

// ---- helpers --------------------------------------------------------------

/// Resolve which project (and optional task) to use for start/update:
///   - explicit numeric `-p <id>` is used directly;
///   - a `-p <name>` that uniquely matches the cache is used as-is;
///   - otherwise the interactive picker opens (pre-filtered by any name text).
/// Returns null for "no project" (picker cancelled or no terminal).
fn resolveProject(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    client: *api.Client,
    opts: Opts,
) !?cache.Entry {
    if (opts.project_id) |pid| {
        return cache.Entry{ .label = "", .project_id = pid, .task_id = null };
    }

    const entries = try ensureCache(arena, io, env, client);

    if (opts.project_query) |q| {
        var match: ?cache.Entry = null;
        var count: usize = 0;
        for (entries) |e| {
            if (containsIgnoreCase(e.label, q)) {
                match = e;
                count += 1;
            }
        }
        if (count == 1) return match;
    }

    return picker.pick(arena, io, entries, opts.project_query orelse "");
}

/// Return cached entries, refreshing from the API if missing or stale.
fn ensureCache(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    client: *api.Client,
) ![]cache.Entry {
    if (try cache.load(arena, io, env)) |c| {
        if (c.isFresh(timefmt.nowUnix(io))) return c.entries;
    }
    const entries = try cache.build(arena, client);
    try cache.save(arena, io, env, .{ .synced_at = timefmt.nowUnix(io), .entries = entries });
    return entries;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "containsIgnoreCase finds case-insensitive substrings" {
    try std.testing.expect(containsIgnoreCase("Acme / Backend", "backend"));
    try std.testing.expect(containsIgnoreCase("Acme / Backend", "ME / BA"));
    try std.testing.expect(!containsIgnoreCase("Acme / Backend", "frontend"));
    try std.testing.expect(containsIgnoreCase("anything", ""));
}

test "lookupLabel resolves project and task names" {
    const labels = [_]cache.Entry{
        .{ .label = "Acme / Backend", .project_id = 1, .task_id = null },
        .{ .label = "Acme / Backend / Auth", .project_id = 1, .task_id = 10 },
        .{ .label = "Globex / Web", .project_id = 2, .task_id = null },
    };
    try std.testing.expectEqualStrings("Acme / Backend", lookupLabel(&labels, 1, null).?);
    try std.testing.expectEqualStrings("Acme / Backend / Auth", lookupLabel(&labels, 1, 10).?);
    // Unknown task on a known project falls back to the project label.
    try std.testing.expectEqualStrings("Acme / Backend", lookupLabel(&labels, 1, 999).?);
    try std.testing.expect(lookupLabel(&labels, 42, null) == null);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Build an authenticated client, resolving the token from the environment or
/// the saved config (env wins).
fn makeClient(arena: std.mem.Allocator, io: Io, env: *std.process.Environ.Map) !api.Client {
    const cfg = try config.load(arena, io, env);

    const token = env.get("TOGGL_API_TOKEN") orelse blk: {
        if (cfg.api_token.len > 0) break :blk cfg.api_token;
        color.eprint(
            "No API token found. Run `toggl auth <token>` or set TOGGL_API_TOKEN.\n",
            .{},
        );
        return error.NoToken;
    };

    var client = try api.Client.init(arena, io, token);
    client.workspace_id = cfg.workspace_id;
    return client;
}

const Opts = struct {
    description: ?[]const u8 = null,
    /// Set when `-p` is a numeric id.
    project_id: ?i64 = null,
    /// Set when `-p` is a non-numeric name fragment to match/pick.
    project_query: ?[]const u8 = null,
    tags: std.ArrayList([]const u8) = .empty,
    positionals: std.ArrayList([]const u8) = .empty,

    fn tagsSlice(self: *const Opts) ?[]const []const u8 {
        return if (self.tags.items.len == 0) null else self.tags.items;
    }
};

fn parseOpts(arena: std.mem.Allocator, args: []const [:0]const u8) !Opts {
    var opts: Opts = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eql(a, "-p") or eql(a, "--project")) {
            const v = try nextValue(args, &i, "project");
            // A bare integer is a project id; anything else is a name to match.
            if (std.fmt.parseInt(i64, v, 10)) |id| {
                opts.project_id = id;
            } else |_| {
                opts.project_query = v;
            }
        } else if (eql(a, "-t") or eql(a, "--tag")) {
            try opts.tags.append(arena, try nextValue(args, &i, "tag"));
        } else if (eql(a, "-d") or eql(a, "--description")) {
            opts.description = try nextValue(args, &i, "description");
        } else {
            try opts.positionals.append(arena, a);
        }
    }
    return opts;
}

fn nextValue(args: []const [:0]const u8, i: *usize, name: []const u8) ![]const u8 {
    if (i.* + 1 >= args.len) {
        color.eprint("missing value for --{s}\n", .{name});
        return error.Usage;
    }
    i.* += 1;
    return args[i.*];
}

/// Best-effort load of cached project/task labels for display. Never triggers
/// a network sync; returns an empty slice when there's no cache yet (names
/// then fall back to ids until the next `toggl sync` / picker use).
fn loadLabels(arena: std.mem.Allocator, io: Io, env: *std.process.Environ.Map) []const cache.Entry {
    const c = cache.load(arena, io, env) catch return &.{};
    return if (c) |cc| cc.entries else &.{};
}

/// Find a display label for a (project_id, task_id) pair among cached entries.
/// Prefers an exact task match, then the bare project, then any entry for the
/// project. Returns null if nothing matches.
fn lookupLabel(labels: []const cache.Entry, project_id: i64, task_id: ?i64) ?[]const u8 {
    if (task_id) |tid| {
        for (labels) |l| {
            if (l.project_id == project_id and l.task_id != null and l.task_id.? == tid) return l.label;
        }
    }
    for (labels) |l| {
        if (l.project_id == project_id and l.task_id == null) return l.label;
    }
    for (labels) |l| {
        if (l.project_id == project_id) return l.label;
    }
    return null;
}

fn printEntry(io: Io, out: *Io.Writer, e: api.Client.TimeEntry, labels: []const cache.Entry, zone: localtz.Zone) !void {
    // Description is the headline (bold); a missing/empty one stands out in red.
    try out.writeAll("  ");
    const desc: ?[]const u8 = if (e.description) |d| (if (d.len > 0) d else null) else null;
    if (desc) |d|
        try color.write(out, .bold, d)
    else
        try missing(out, "NO DESCRIPTION PROVIDED");
    try out.writeByte('\n');

    if (e.project_id) |pid| {
        try color.write(out, .gray, "    project: ");
        if (lookupLabel(labels, pid, e.task_id)) |name| {
            try color.write(out, .cyan, name);
        } else {
            // Not in the cache yet (run `toggl sync`); fall back to ids.
            try color.on(out, .cyan);
            try out.print("#{d}", .{pid});
            try color.off(out);
            if (e.task_id) |tid| {
                try color.write(out, .gray, "   task: ");
                try color.on(out, .cyan);
                try out.print("#{d}", .{tid});
                try color.off(out);
            }
        }
        try out.writeByte('\n');
    } else {
        // No project at all — call it out in red.
        try color.write(out, .gray, "    project: ");
        try missing(out, "NO PROJECT PROVIDED");
        try out.writeByte('\n');
    }

    const start_epoch: ?i64 = if (e.start) |s| timefmt.parseRfc3339(s) else null;

    if (e.duration < 0) {
        // Running: prefer computing elapsed from the parsed start (robust to
        // however Toggl encodes the negative duration), else fall back.
        const elapsed = if (start_epoch) |se| timefmt.nowUnix(io) - se else timefmt.nowUnix(io) + e.duration;
        try color.write(out, .gray, "    elapsed: ");
        try color.on(out, .green);
        try printDuration(out, elapsed);
        try out.writeAll(" (running)");
        try color.off(out);
        try out.writeByte('\n');
    } else {
        try color.write(out, .gray, "    duration: ");
        try printDuration(out, e.duration);
        try out.writeByte('\n');
    }

    if (start_epoch) |se| try printLocal(out, zone, se, "started");
    if (e.stop) |s| if (timefmt.parseRfc3339(s)) |pe| try printLocal(out, zone, pe, "stopped");

    if (e.tags) |tags| {
        if (tags.len > 0) {
            try color.write(out, .gray, "    tags: ");
            for (tags, 0..) |tag, idx| {
                if (idx != 0) try out.writeAll(", ");
                try color.write(out, .yellow, tag);
            }
            try out.writeByte('\n');
        }
    }
}

/// Print a "    <label>: YYYY-MM-DD HH:MM ABBR" line in local time (no alloc).
fn printLocal(out: *Io.Writer, zone: localtz.Zone, epoch: i64, label: []const u8) !void {
    var buf: [32]u8 = undefined;
    const rfc = try timefmt.epochToRfc3339(epoch + zone.offsetAt(epoch), &buf);
    try color.on(out, .gray);
    try out.print("    {s}: ", .{label});
    try color.off(out);
    try out.print("{s} {s} {s}\n", .{ rfc[0..10], rfc[11..16], zone.abbrevAt(epoch) });
}

/// Print a bold, colored section header line (e.g. "Started:", "Running:").
fn header(out: *Io.Writer, style: color.Style, text: []const u8) !void {
    try color.on(out, .bold);
    try color.on(out, style);
    try out.writeAll(text);
    try color.off(out);
    try out.writeByte('\n');
}

/// Write a standout placeholder (bold red) for a missing field value.
fn missing(out: *Io.Writer, text: []const u8) !void {
    try color.on(out, .bold);
    try color.on(out, .red);
    try out.writeAll(text);
    try color.off(out);
}

/// Build an editor-menu row whose value is a missing-field placeholder: gray
/// label, bold-red value (e.g. "Project:      (none)").
fn fieldRowMissing(arena: std.mem.Allocator, label: []const u8, value: []const u8) ![]const u8 {
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try color.write(w, .gray, label);
    try missing(w, value);
    return out.written();
}

/// Print a dim horizontal rule `cols` columns wide — the `toggl list` separator.
fn divider(out: *Io.Writer, cols: usize) !void {
    try color.on(out, .dim);
    var i: usize = 0;
    while (i < cols) : (i += 1) try out.writeAll("\u{2500}"); // ─
    try color.off(out);
    try out.writeByte('\n');
}

fn printDuration(out: *Io.Writer, secs_in: i64) !void {
    const secs: u64 = if (secs_in < 0) 0 else @intCast(secs_in);
    const h = secs / 3600;
    const m = (secs % 3600) / 60;
    const s = secs % 60;
    try out.print("{d}h {d:0>2}m {d:0>2}s", .{ h, m, s });
}
