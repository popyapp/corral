<div align="center">

<img src="Assets/icon.svg" width="180" alt="Corral icon">

# Corral

**Corral your runaway coding agents.**

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
  button.

Supported: **Claude Code**, **Claude** (desktop), **Codex**, **Cursor** and its
CLI agent, **Windsurf**.

## Install

Build from source (macOS 13+, Xcode command line tools):

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
Corral --list           # human-readable
Corral --list --json    # machine-readable
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

## Building

```sh
make build   # swift build
make app     # build/Corral.app
make list    # run the CLI against your own machine
make icon    # regenerate the .icns (needs librsvg)
make clean
```

## License

MIT
