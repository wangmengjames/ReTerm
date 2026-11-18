# ReTerm

A tiny macOS menu bar app that closes all your Terminal windows in one click and remembers them, so you can reopen any of them later. Like "reopen closed tab" in a browser, for Terminal.app.

It is built for people who keep many [Claude Code](https://claude.com/claude-code) sessions open: each saved entry remembers the folder and the session, and reopening it runs `claude --resume <session>` in the right folder for you.

## What it does

- **Save & Close All Terminal Windows**: records every open Terminal tab, then closes them. It warns you first if any Claude session is still working.
- **Save Snapshot Only**: records the tabs without closing anything.
- **Reopen**: click any saved entry to get it back in a new Terminal window. Claude Code sessions are resumed; plain shells open in their folder. Reopened entries get a tick.
- **Reopen All Not Yet Reopened**: brings back the rest of a snapshot.
- **Earlier**: the last 15 snapshots are kept.
- **Launch at Login**: optional.

## Install

Requires macOS 13 or later and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/wangmengjames/ReTerm.git
cd ReTerm
./build.sh install
open ~/Applications/ReTerm.app
```

The first time you use **Save & Close**, macOS asks whether ReTerm may control Terminal. Allow it. This is only used to find and close Terminal windows. You can change it later in System Settings › Privacy & Security › Automation.

## How it works

- Open tabs are found from the process table: every `login` process started by Terminal.app is one tab.
- If a Claude Code process is running in a tab, its folder and session id are read from `~/.claude/sessions/<pid>.json`. Otherwise the folder of the innermost process in the tab is used.
- Closing sends `SIGHUP` to the processes in each tab (the same signal Terminal sends when you close a window), then asks Terminal to close the now-idle windows.
- Reopening writes a small `.command` script and opens it with Terminal. Claude is started through your interactive login shell, so your own aliases and `PATH` apply.
- History is stored in `~/Library/Application Support/ReTerm/history.json`. Nothing leaves your Mac.

## Limits

- Terminal.app only (not iTerm2, Ghostty or the VS Code terminal).
- Scrollback and running commands are not restored. A plain shell comes back as a new shell in the same folder.
- A window that mixes tabs is closed only when all of its tabs are being closed, which is always the case for Save & Close All.
- The format of `~/.claude/sessions` is not a documented interface and may change between Claude Code versions.

## Command line

The app binary has a few read-only helpers for checking what it sees:

```sh
~/Applications/ReTerm.app/Contents/MacOS/ReTerm --list      # tabs that would be saved now
~/Applications/ReTerm.app/Contents/MacOS/ReTerm --history   # saved snapshots
```

## License

MIT
