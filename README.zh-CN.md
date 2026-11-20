<p align="center"><img src="docs/icon.png" width="128" alt="ReTerm icon"></p>

<h1 align="center">ReTerm</h1>

**给 Terminal 窗口和 Claude Code 会话用的"重新打开关闭的标签页"。**

[English](README.md) | 简体中文

ReTerm 是一个很小的 macOS 菜单栏工具。点一下，关掉所有 Terminal 窗口并记住它们；之后在 ReTerm 的面板里点任意一条，它就在原来的文件夹里重新打开，[Claude Code](https://claude.com/claude-code) 会话也自动恢复。

会话还开着的时候，同一个面板会列出所有正在运行的会话，不管它在哪里（Terminal、iTerm2、VS Code、Claude App），菜单栏图标旁边还会显示有几个在等你处理。

<p align="center"><img src="docs/panel.png" width="400" alt="ReTerm 面板：正在运行的 Claude Code 会话、状态和“完成”按钮，下面是今天完成的会话和“打开”按钮"></p>

## 为什么做这个

同时开着好几个 Claude Code 会话时，桌面上会堆满不敢关的 Terminal 窗口：一旦关掉，想找回来就得先进对应文件夹，再运行 `claude --resume`，然后从列表里挑出正确的那个会话。ReTerm 把这些变成点一下。

## 功能

- **实时会话列表**：列出每个正在运行的 Claude Code 会话，显示它在做什么（*Permission request* 权限请求、*Your turn* 等你回复、*Working* 运行中）、在哪个 App 里、持续了多久。点一下就跳到它的窗口：精确到 Terminal 或 iTerm2 的那个标签页、打开着那个文件夹的 VS Code 窗口，或者 Claude App 里的那个会话。
- **标记为已完成**：点 Terminal 会话右边的 **完成**，就把它存进 **今天完成** 并关掉窗口，之后随时可以从那里重新打开，对话自动恢复。如果会话还在工作，会先问你。
- **直接关窗口也不会丢**：在 Terminal.app 里运行的 Claude Code 会话，如果不是通过 ReTerm 结束的（你关掉了它的窗口、输入了 `/exit` 或 `/clear`、退出了 Terminal，或者重启了电脑），会自动存进 **今天关闭**，随时可以重新打开并恢复对话。可以在 ⚙︎ 设置里用 **自动记住我自己关掉的会话** 关闭这个功能。
- **需要你处理的数量**：菜单栏图标旁边的数字，是停在权限请求或问题上、等你处理的会话数。
- **隐藏会话标题**（在 ⚙︎ 设置里）：用文件夹名代替会话标题，适合共享屏幕时使用。
- **中文或英文**：默认跟随系统语言，也可以在 ⚙︎ 设置里选。
- **Save & Close All Terminal Windows**：记录所有打开的 Terminal 标签页后全部关闭。如果有 Claude 会话还在工作，会先提醒。
- **Close All, Update Claude Code & Reopen（全部关闭、更新 Claude Code 再重新打开）**：保存并关闭所有 Terminal 标签页，运行 `claude update`，再把原来的标签页重新打开，每个 Claude 会话在新版本上继续。更新失败时标签页照样会恢复，并显示 `claude update` 的输出。
- **一眼能认出来的条目**：每条显示会话标题（就是 Claude Code 写在窗口标题栏上的那句话）和所在文件夹。
- **恢复单个或全部**：Claude Code 会话用 `claude --resume` 恢复；普通 shell 在原文件夹重新打开。已恢复的条目会打勾。
- **历史记录**：今天的记录全部展开显示；更早的（最近 30 组）收在 **更早** 里。
- **Save Snapshot Only**：只记录，不关闭。
- **窗口回到原来的位置**：重新打开的窗口会回到保存时的位置和大小。
- **用键盘恢复上一个**：在任何地方按 `⌃⌥⌘T`，就把最近关闭的那个标签页找回来，像浏览器里的 `⌘⇧T`。
- **搜索与管理**（放大镜图标）：把 ReTerm 记住的所有内容放在一个可搜索的列表里，可以重新打开、置顶或删除；置顶的条目固定显示在面板上方，不会被新记录挤掉。
- **也支持 Codex CLI 会话**：运行 OpenAI Codex 的 Terminal 标签页会连同会话一起保存，重新打开时用 `codex resume` 恢复。
- **内置更新**：**Check for Updates…** 一键安装最新版并重启。
- 小而原生：几千行 Swift，无第三方依赖，同时支持 Apple 芯片和 Intel。

## 安装

把下面这行粘贴到 Terminal：

```sh
curl -fsSL https://raw.githubusercontent.com/wangmengjames/ReTerm/main/install.sh | zsh
```

它会把最新版下载到 `~/Applications` 并启动。之后在菜单栏找新出现的图标。

<details>
<summary>其他安装方式</summary>

**手动下载。** 从[最新 Release](https://github.com/wangmengjames/ReTerm/releases/latest) 下载 `ReTerm.zip`，解压后把 `ReTerm.app` 拖到"应用程序"文件夹。这个 App 没有经过 Apple 公证，第一次打开会被拦截：到"系统设置 › 隐私与安全性"里点**仍要打开**。用上面的安装命令可以省掉这一步。

**从源码编译。** 需要 Xcode 命令行工具（`xcode-select --install`）。

```sh
git clone https://github.com/wangmengjames/ReTerm.git
cd ReTerm
./build.sh install
open ~/Applications/ReTerm.app
```

</details>

第一次使用 **Save & Close** 时，macOS 会询问是否允许 ReTerm 控制 Terminal，请点允许。这个权限只用来查找、切换、关闭 Terminal 窗口和恢复窗口位置。

## 隐私

记录只保存在本机的 `~/Library/Application Support/ReTerm/history.json`。ReTerm 唯一的联网行为是每天最多一次访问 GitHub API，查看有没有新版本。

## 限制

- 保存、关闭和恢复只支持系统自带的 Terminal.app（不支持 iTerm2、Ghostty、VS Code 终端）。实时会话列表支持 Terminal、iTerm2、VS Code 及同类编辑器（Cursor、Windsurf、VSCodium）和 Claude App；tmux 里的会话会列出来，但不能跳转。“标记为已完成”只支持 Terminal 里的会话；如果它的标签页和别的标签页在同一个窗口里，会话会结束，但那个标签页会留着。
- 自动记录"自己关掉的会话"只支持 Terminal.app 里的会话（不含 iTerm2、VS Code、Claude App 和 tmux）。从没发过消息的会话不记录。每天的 **关闭** 分组最多保留 40 个会话。
- 不恢复滚动历史和正在运行的命令；普通 shell 恢复为同一文件夹里的新 shell。
- `~/.claude/sessions` 和会话记录的格式不是公开接口，可能随 Claude Code 版本变化。
- 更新后 macOS 可能会再问一次是否允许控制 Terminal，因为 App 没有用开发者证书签名。

## 卸载

在面板里退出 ReTerm，然后删除 `~/Applications/ReTerm.app` 和 `~/Library/Application Support/ReTerm`。

## 许可

MIT
