<div align="center">

<img src="Assets/icon.svg" width="180" alt="Corral icon">

# Corral

**Activity Monitor for Your Local AI Agents**

A free, open-source, native macOS app that shows you every Claude Code, Codex
and Cursor process on your machine — what project it belongs to, how long it has
been sitting there, and how much of your Mac it is holding.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue?style=flat-square)](LICENSE)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black?style=flat-square&logo=apple)
![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?style=flat-square&logo=swift&logoColor=white)

</div>

## Why

Open Activity Monitor while you have a few agent sessions going and you get
this:

```
2.1.228    5,8%   6:46:58.81   39 threads
2.1.231    2,0%   1:18:17.04   39 threads
2.1.228    1,5%   1:48:52.33   39 threads
2.1.228    1,5%   1:23:59.63   39 threads
2.1.232    1,2%   1:13:19.57   39 threads
```

Fifteen identical rows named after a version number. Claude Code installs itself
as `~/.local/share/claude/versions/2.1.228`, so the process name *is* the
version — and nothing on that screen tells you which of them is the session you
abandoned in a repo last Tuesday and which is the one doing your actual work.

So people reach for `pkill -9 -f claude`, kill everything including the session
they were in the middle of, and move on.

Corral shows you the same processes with the one fact that makes them
distinguishable — **the working directory** — plus how long each has really been
idle, what it spawned, and what it is costing you.

## What it shows

- **The project, not the version.** Each agent is identified by its working
  directory, so the list reads `heroshot`, `recall`, `appcleaner` — not
  `2.1.228` five times.
- **Honest idle time.** Not "quiet since this app opened": Corral reads the last
  write to each agent's controlling terminal, which the kernel has been stamping
  all along. An agent you walked away from on Tuesday says `idle 3.1d` the first
  second you open the window.
- **The whole footprint.** Every agent's children — MCP servers, `node` helpers,
  the `caffeinate` that has been quietly stopping your Mac from sleeping — and
  the memory they hold together.
- **Where it came from.** Executable path, full command line, parent process,
  controlling terminal, start time.
- **What is safe to reclaim.** Agents idle for over an hour, totalled, behind one
  button. Anything still working — including an agent waiting on a build it
  started — is never in that total.
- **A menu bar item.** Corral keeps running with its window closed, and the top
  right shows the busiest agent's CPU — or just how many are running when
  nothing is working hard. Hover for the summary, click for the list, click a
  row to open the window on that agent.
- **The tool's own icon.** Taken from the copy of Claude, Cursor or ChatGPT
  already installed on your Mac, the same way Finder draws it. Corral ships no
  brand artwork; a tool you do not have installed falls back to a symbol.
- **Where the numbers have been.** One graph in the header, plotting CPU by
  default. Click a figure — agents, memory, projects, cores — to plot that one
  instead; click the graph to switch between 15 minutes, 1 hour and 3 hours.
  "2.92 GB" cannot tell you whether that is the calm after you closed six agents
  or the start of a climb; the graph can. A missing column is a stretch when
  Corral was not running — it will not draw across a sleep it did not observe.
- **Sorting.** By how long it has been running (the default — the thing you
  forgot about is the thing you came here to find), by memory, by CPU across the
  whole group, or by project name. Each order has an obvious direction, so
  picking one applies it; picking the same one again reverses it. Remembered
  between launches.
- **Search.** ⌘F in either pane. An agent matches on its project, path, tool,
  version, pid, terminal, command line — and on what it spawned, so searching
  for an MCP server finds the agent running it.
- **What they left on disk.** A second tab measures every cache, superseded
  version and log the tools have accumulated, sorted by how safe it is to
  remove. On the machine this was written on that came to 14 GB.

Supported: **Claude Code**, **Claude** (desktop), **Codex**, **Cursor** and its
CLI agent, **Windsurf**.

## What the colours mean

Every row carries a dot. There are five states, and each one is a different
decision:

| | State | Means |
|---|---|---|
| 🟢 | **working** | Using the CPU, or writing to its terminal right now. |
| 🔵 | **waiting** | The agent is parked, but a build, test run or MCP server *it started* is busy. It is waiting on its own work. |
| ⚪ | **idle** | Nothing for under an hour. Normal between prompts. |
| 🟡 | **idle** (amber) | Nothing for an hour to a day. Worth a look. |
| 🔴 | **abandoned** | Nothing for over a day. Almost certainly forgotten. |

The same legend is in the app, behind the **?** next to the search field.

**How it is measured, and what that cannot see.** Corral watches two things: how
much CPU a process has used since the last sample, and the last write to its
controlling terminal. It does not watch the network, so an agent waiting on a
reply from the model is, strictly, doing neither. In practice that gap stays
green: CLI agents animate a thinking indicator while they wait, and that redraw
is a terminal write. Output within the last 30 seconds counts as working.

Two honest limits:

- **`waiting` is inferred from children, not from the agent.** A `swift build`
  burning a core proves its agent is working; an agent thinking quietly with no
  children and no output does not look busy, because nothing observable says it
  is. Before this existed, such a group read as plain `idle` — and was offered
  up to the Reclaim button along with the genuinely forgotten ones.
- **An agent with no controlling terminal has only CPU to go on.** Its idle time
  can then only reach back to when Corral opened, which is why those rows say
  "quiet since Corral opened" rather than "idle", and why they are never
  bulk-stopped. `corral list` makes the same distinction in text.

## What it costs to run

A monitor that shows you what is eating your CPU has no business being on that
list. A refresh takes **~8 ms** across ~550 processes — 0.4% of one core at the
two-second refresh rate. Measure it yourself with `Corral --bench`.

That took work. The first version read every process's argument vector every
tick, which allocates a megabyte a time, and cost 17% of a core. The fix is that
almost nothing about a process changes: its path, its arguments, its terminal
and what tool it belongs to are all fixed at birth, so they are asked once and
cached against the pid and its start time. Only memory and CPU are re-read.

## On disk

```
  20 items · 13,97 GB total
  (skipping versions in use: 2.1.227, 2.1.228, 2.1.231, …)

  SAFE TO CLEAR — 1,44 GB
    554,9 MB    Network cache            ~/Library/Application Support/Claude/Cache
    294,7 MB    Superseded versions      ~/.local/share/claude/versions/2.1.229
    …
  WILL BE DOWNLOADED AGAIN — 11,94 GB
    10,89 GB    Local agent VM image     ~/Library/Application Support/Claude/vm_bundles
     1,05 GB    Plugin cache             ~/.claude/plugins/cache
  YOUR DATA — 591,9 MB
    520,6 MB    Conversation history     ~/.claude/projects
```

Three groups, because "reclaimable" is not one thing:

- **Safe to clear** — caches the app rebuilds by itself. Ticked by default.
- **Will be downloaded again** — big, and fetched again on demand. Your call.
- **Your data** — transcripts, undo history, extensions. **Never** ticked for you.

A version that is currently running is never offered, whatever its number says.
Everything goes to the Trash, never `unlink`.

## Install

Download the latest `Corral-<version>.dmg` from the
[releases page](https://github.com/popyapp/corral/releases), open it and drag
Corral to Applications. Every commit on `main` publishes a build, each one
listing its SHA-256 and the exact commit it came from — `Corral --version`
prints that commit back to you, and **About Corral** shows the same pair as
`Version 0.1.5 (a1b2c3d)`, with the hash linking to that commit on GitHub.

A build made locally with `make app` has no release number, so it takes one
from git instead: the last release tag plus how far past it the tree is, as
`0.1.5+3`. If the tree had uncommitted changes the hash carries a `-dirty`
suffix, and About says the binary matches no commit at all.

Builds are ad-hoc signed rather than notarised, so the first launch needs
right-click → Open.

Or build from source (macOS 13+, Xcode command line tools):

```sh
git clone https://github.com/popyapp/corral.git
cd corral
make app        # builds build/Corral.app
open build      # then drag Corral.app to /Applications
```

Or during development:

```sh
swift run Corral            # the window
swift run Corral --list     # the same inventory, printed
```

## Terminal mode

```sh
Corral --list                  # human-readable
Corral --list --json           # machine-readable
Corral --list --search recall  # only agents matching a project, tool or pid
Corral --disk           # what is on disk (read-only; nothing is deleted)
Corral --bench          # how much a refresh costs
```

```
  17 agents · 98 processes · 2,44 GB · 11 projects · 17 idle

  Claude Code 2.1.227  ·  pid 5777
    project   ~/code/heroshot
    up        6.1d    cpu 39.2s    mem 88,5 MB    idle 15.0h
    tty       /dev/ttys016
    children  4 — node (MCP server, pid 5800), node (MCP server, pid 5801), …
```

## Stopping things

- **Quit** sends `SIGTERM` — the agent gets to exit cleanly — then waits and
  tells you honestly if anything ignored it.
- **Force Quit** sends `SIGKILL`.
- Either way, **children are stopped before the agent**. Kill the agent first
  and its MCP servers get reparented to `launchd`, where they sit forever with
  nobody to talk to — which is exactly the mess this app exists to clean up.
- Corral refuses to signal anything that isn't yours, and never signals `launchd`
  or itself.

## Privacy and permissions

Corral needs **no special permissions** — no Full Disk Access, no accessibility,
no entitlements. Every fact it shows is already readable by any process running
as you: `sysctl` for the process table and argument vectors, `proc_pidinfo` for
working directories, `proc_pid_rusage` for CPU and memory.

It reads the *argument* vector and deliberately stops there — the environment
block sits right after it in the same buffer and is full of API keys, so Corral
never reads that far.

Nothing leaves your machine. There is no network code in this app.

## Tests

```sh
swift test
```

Cursor, Codex and Windsurf have to work on a machine that has never run them, so
most of the suite feeds the catalog the exact executable paths those tools
produce — including `CursorUIViewService`, the macOS text-input helper that a
naive name match would list as Cursor and offer to kill.

The live tests go further: they **compile a small binary named `codex`**, run it
in a temp project directory, and assert Corral finds it, names the project, and
can stop it. Copying `/bin/sleep` and renaming it does not work — macOS SIGKILLs
an Apple-signed binary running from the wrong place — so the test builds its own.

## Building

```sh
make build   # swift build
make test    # swift test
make app     # build/Corral.app
make dmg     # build/Corral-<version>.dmg, mounted and verified
make list    # run the CLI against your own machine
make icon    # regenerate the .icns (needs librsvg)
make clean
```

## License

MIT
