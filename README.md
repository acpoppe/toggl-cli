# toggl

A small, fast command-line client for [Toggl Track](https://toggl.com/track/) — start, stop, and edit time entries without leaving the terminal. Built in Zig as a single, dependency-free binary you can drop on your `PATH`.

The whole point is to *not* make you look things up: you never type project IDs. When a command needs a project, an interactive fuzzy picker opens; times are shown in your local timezone; and editing past entries is a guided menu.

## Features

- **Start / stop / status / resume** the running timer. `start` won't silently replace a running entry, and `resume` continues your most recent one (after a confirmation).
- **Add & delete** entries — log a past or running entry from scratch, or delete one behind a confirmation prompt.
- **Interactive project selection** — fuzzy-filter your workspace's projects and tasks ("sub-projects") instead of memorizing IDs.
- **Interactive editor** for any recent entry: change description, project, tags, and start/stop times from a menu.
- **Week calendar** (`toggl viz`) — a full-screen, colored week view of your entries, paginated by week, with overlaps shown side by side.
- **Colorized output** that honors `NO_COLOR`; the calendar uses each project's own Toggl color.
- **Local timezone** display (DST-aware, read from the system tz database); relative time edits like `-15m` for "I forgot to start".
- **Vim-friendly** navigation in all lists (`j`/`k`, `Ctrl-J`/`Ctrl-K`, arrows).
- **Zero dependencies** — just the Zig standard library. One static binary.

## Requirements

- **Zig 0.16.0** (to build).
- A **Toggl Track** account and **API token** (Profile settings → API Token).
- **macOS or Linux.** It uses POSIX terminal APIs and reads `/etc/localtime`; Windows isn't supported.

## Install

### Homebrew

```sh
brew install acpoppe/tap/toggl
```

### Prebuilt binaries

Download the tarball for your platform from the [Releases](../../releases) page,
then extract and put it on your `PATH`:

```sh
tar -xzf toggl-aarch64-macos.tar.gz
mv toggl ~/.local/bin/                 # or any directory on your $PATH
```

The macOS binaries are signed and notarized, so they run without a Gatekeeper
prompt (an internet connection is needed on first launch). Verify a download
against the release's `SHA256SUMS` if you like.

### Build from source

```sh
zig build --release=safe
cp zig-out/bin/toggl ~/.local/bin/     # or any directory on your $PATH
```

Then confirm it's reachable:

```sh
toggl help
```

## Setup

Authenticate once. Your token (and default workspace) are saved to `~/.config/toggl-cli/config.json`:

```sh
toggl auth <your_api_token>
```

Alternatively, set `TOGGL_API_TOKEN` in your environment — it overrides the config file.

Then sync your projects/tasks so names show up everywhere:

```sh
toggl sync
```

## Usage

```
toggl auth <api_token>             Save your API token + default workspace
toggl start <description> [opts]   Start a new running time entry
toggl resume                       Resume the most recent entry        (alias: continue)
toggl stop                         Stop the currently running entry
toggl status                       Show the currently running entry    (alias: current)
toggl update [opts]                Edit an entry (interactive, or running with flags)
toggl add                          Add a new entry via the editor
toggl delete                       Delete an entry (confirms first)    (alias: rm)
toggl list [count]                 List recent entries, default 10     (alias: ls)
toggl viz                          Full-screen week calendar
toggl sync                         Refresh the cached project/task list
toggl version                      Print the version (also --version, -v)
toggl help [command]               Help, optionally for one command
```

Run `toggl help <command>` or `toggl <command> --help` for details on any command.

### Starting an entry

```sh
toggl start "writing docs"            # opens the project picker (Esc = no project)
toggl start fixing the build -p backend   # match a project by name
toggl start review -p 12345 -t urgent     # explicit project id + a tag
```

Options for `start`:

- `-p, --project <id|name>` — a project id, or a name fragment. A unique name match is used directly; otherwise the picker opens, pre-filtered. Omit it entirely and the picker opens automatically.
- `-t, --tag <tag>` — add a tag (repeatable).
- `-d, --description <s>` — set the description explicitly.

If an entry is already running, `start` refuses rather than silently switching — stop it first (`toggl stop`) or continue it with `toggl resume`.

### Resuming an entry

```sh
toggl resume     # shows your most recent entry, asks to confirm, then continues it
```

`resume` (alias `continue`) copies the most recent entry's description, project, task, and tags into a new running entry (a fresh start time). It shows the entry and waits for a `y`/`N` confirmation first, and is refused if something is already running.

### Editing entries

```sh
toggl update                 # interactive: pick an entry, then edit via a menu
toggl update -d "new name"   # non-interactive: update the running entry
toggl update -p backend
```

With no flags, `update` lets you choose **any** recent entry (not just the running one), then opens a field menu to change its description, project, tags, or **start/stop time**. Times accept:

- a relative offset — `-15m`, `+1h30m` (applied to the current value), or
- an absolute **local** time — `2026-05-24 14:30`, or `09:00` for that time today.

With flags, it updates the running entry directly.

### Adding an entry

```sh
toggl add     # opens the editor on a new, blank entry
```

`add` uses the same field menu as `update`, on a new entry seeded with the current time. Set description, project, tags, and times, then **Save**. The start time is the only required field: leave the **stop** empty to create a running entry (refused if one is already running), or set a stop to log a completed past entry. Times accept the same relative (`-45m`, relative to now) or absolute (`2026-05-24 14:30`) formats as `update`.

### Deleting an entry

```sh
toggl delete     # pick an entry, then confirm
```

`delete` (alias `rm`) opens the same fuzzy chooser as `update`, shows the entry you picked, and asks for confirmation before permanently deleting it. Deletion can't be undone.

### Listing

```sh
toggl list        # 10 most recent
toggl list 25     # 25 most recent
```

Entries are shown most-recent-first, with project names and local start/stop times.

### Week calendar

```sh
toggl viz
```

A full-screen week view — days as columns, hours as rows, each entry a filled block in its Toggl project color (run `toggl sync` first so the colors are available). It fills the terminal and re-renders when you resize the window; overlapping entries are split side by side.

| Key | Action |
|---|---|
| `←` / `→` or `p` / `n` | previous / next week |
| `t` | jump to the current week |
| `r` | refresh (re-fetch the current week; updates a running timer) |
| `q` / `Esc` | quit |

Needs a color terminal — truecolor is used when available, otherwise the nearest 256- or 16-color match.

## Keys (interactive lists)

| Context | Down | Up | Select | Cancel |
|---|---|---|---|---|
| Fuzzy lists (type to filter) | `Ctrl-J` / `Ctrl-N` / `↓` | `Ctrl-K` / `Ctrl-P` / `↑` | `Enter` | `Esc` |
| Fixed menus (the editor) | `j` / `↓` | `k` / `↑` | `Enter` | `Esc` |

In the line editor (description/tags), `←`/`→` move, `Backspace` deletes, `Ctrl-U` clears, `Esc` keeps the old value.

## Configuration & data

| Path | What |
|---|---|
| `~/.config/toggl-cli/config.json` | API token + default workspace |
| `~/.config/toggl-cli/cache.json` | Cached projects/tasks for the picker (24h TTL; refresh with `toggl sync`) |

The token is stored in plain text. The project/task list is cached locally because Toggl's API rate limits are low and so the picker stays instant and offline-friendly.

## Notes & limitations

- **List reaches back ~90 days.** Toggl's time-entries endpoint won't serve entries older than that; older history would need their separate Reports API.
- **Absolute times are local**, converted to UTC for the API. Relative offsets (`-15m`) are timezone-agnostic.
- Times are read from `/etc/localtime`; if it can't be read, display falls back to UTC.
- **Color** is on by default when writing to a terminal and respects `NO_COLOR` (and `CLICOLOR_FORCE`). Stdout and stderr are detected independently, so errors stay colored even when output is piped.

## Development

```sh
zig build            # debug build -> zig-out/bin/toggl
zig build run -- status
zig build test       # run unit tests
```

Two hidden commands let you try the terminal UI with no account or network:

```sh
toggl pickdemo   # the project picker over sample data
toggl editdemo   # the entry field-menu editor over a fake entry
toggl adddemo    # the new-entry editor over sample data
toggl vizdemo    # the week calendar over a sample week
```

### Source layout

| File | Responsibility |
|---|---|
| `src/main.zig` | CLI parsing, command dispatch, output |
| `src/api.zig` | Toggl Track API v9 client |
| `src/cache.zig` | Project/task fetch + local cache (incl. project colors) |
| `src/picker.zig` | Raw-mode fuzzy picker, line editor & confirm prompt |
| `src/color.zig` | ANSI styling + true-color helpers; `NO_COLOR` / depth detection |
| `src/viz.zig` | Full-screen week calendar |
| `src/localtz.zig` | System timezone (IANA tz database) |
| `src/timefmt.zig` | RFC 3339 formatting/parsing & date math |
