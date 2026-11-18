# ReTerm

**"Reopen closed tab", for Terminal windows and Claude Code sessions.**

[![Release](https://img.shields.io/github/v/release/wangmengjames/ReTerm)](https://github.com/wangmengjames/ReTerm/releases/latest)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

English | [简体中文](README.zh-CN.md)

ReTerm is a tiny macOS menu bar app. One click closes every Terminal window and remembers them. Later, pick any one from the menu and it comes back in the right folder, with its [Claude Code](https://claude.com/claude-code) session resumed.

<p align="center"><img src="docs/menu.svg" width="560" alt="Illustration of the ReTerm menu listing closed Terminal windows by session title and folder"></p>

## Why

If you run several Claude Code sessions at once, you end up with a wall of Terminal windows you are afraid to close, because getting one back means finding the folder, running `claude --resume` and picking the right session from a list. ReTerm turns that into one click.

## Features

- **Save & Close All Terminal Windows**: records every open Terminal tab, then closes them. Warns you first if a Claude session is still working.
- **Entries you can recognise**: each one shows the session's title (the same one Claude Code puts in the window title bar) and its folder.
- **Reopen one or all**: Claude Code sessions are resumed with `claude --resume`; plain shells reopen in their folder. Reopened entries get a tick.
- **History**: the last 15 snapshots are kept under **Earlier**.
- **Save Snapshot Only**: record without closing anything.
- **Built-in updates**: **Check for Updates…** installs the newest release and relaunches.
- Small and native: about 600 lines of Swift, no dependencies, universal binary (Apple silicon and Intel).

## Install

Paste this into Terminal:

```sh
curl -fsSL https://raw.githubusercontent.com/wangmengjames/ReTerm/main/install.sh | zsh
```

It downloads the latest release into `~/Applications` and starts it. Look for the new icon in the menu bar.

<details>
<summary>Other ways to install</summary>

**Download manually.** Get `ReTerm.zip` from the [latest release](https://github.com/wangmengjames/ReTerm/releases/latest), unzip it and move `ReTerm.app` to your Applications folder. The app is not notarised by Apple, so the first launch is blocked: open System Settings › Privacy & Security and click **Open Anyway**. The install command above avoids this step.

**Build from source.** Needs the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/wangmengjames/ReTerm.git
cd ReTerm
./build.sh install
open ~/Applications/ReTerm.app
```

</details>

The first time you use **Save & Close**, macOS asks whether ReTerm may control Terminal. Allow it. It is only used to find and close Terminal windows.

## How it works

- Open tabs are found from the process table: every `login` process started by Terminal.app is one tab.
- If a Claude Code process is running in a tab, its folder and session id are read from `~/.claude/sessions/<pid>.json`, and its title from the session transcript. Otherwise the folder of the innermost process in the tab is used.
- Closing sends `SIGHUP` to the processes in each tab (the same signal Terminal sends when you close a window), then asks Terminal to close the now-idle windows.
- Reopening writes a small `.command` script and opens it with Terminal. Claude is started through your interactive login shell, so your own aliases and `PATH` apply.

## Privacy

History is stored locally in `~/Library/Application Support/ReTerm/history.json`. The only network request ReTerm makes is to the GitHub API, at most once a day, to see whether a newer release exists.

## Limits

- Terminal.app only (not iTerm2, Ghostty or the VS Code terminal).
- Scrollback and running commands are not restored. A plain shell comes back as a new shell in the same folder.
- The format of `~/.claude/sessions` and of session transcripts is not a documented interface and may change between Claude Code versions.
- After an update, macOS may ask again for permission to control Terminal, because the app is not signed with a developer certificate.

## Command line

```sh
~/Applications/ReTerm.app/Contents/MacOS/ReTerm --list          # tabs that would be saved now
~/Applications/ReTerm.app/Contents/MacOS/ReTerm --history       # saved snapshots
~/Applications/ReTerm.app/Contents/MacOS/ReTerm --check-update  # current and latest version
```

## Uninstall

Quit ReTerm from its menu, then delete `~/Applications/ReTerm.app` and `~/Library/Application Support/ReTerm`.

## License

MIT
