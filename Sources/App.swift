import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private let model = PanelModel()
    private var updateTimer: Timer?
    private var badgeTimer: Timer?
    private var panelTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "arrow.uturn.backward.square", accessibilityDescription: "ReTerm")
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(togglePanel(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        model.handle = { [weak self] action in self?.handle(action) }
        let host = NSHostingController(rootView: PanelView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        cleanLaunchFolder()

        HotKey.action = { [weak self] in self?.reopenLastClosed() }
        HotKey.register()
        ManageWindowController.shared.onChange = { [weak self] in self?.model.reload() }

        // The count of Claude sessions that need you, next to the icon. Reading a few small files, so often is fine.
        refreshBadge()
        let badge = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshBadge() }
        RunLoop.main.add(badge, forMode: .common)
        badgeTimer = badge

        // Quietly look for a new version at most once a day.
        checkQuietlyIfDue()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkQuietlyIfDue()
        }
    }

    // MARK: Panel

    @objc private func togglePanel(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        guard let button = statusItem.button else { return }
        model.reload()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        // Statuses change while the panel is open; keep them current.
        panelTimer?.invalidate()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.model.reload() }
        RunLoop.main.add(timer, forMode: .common)
        panelTimer = timer
    }

    func popoverDidClose(_ notification: Notification) {
        panelTimer?.invalidate()
        panelTimer = nil
    }

    private func closePanel() {
        if popover.isShown { popover.performClose(nil) }
    }

    private func handle(_ action: PanelAction) {
        switch action {
        case .jump(let session):
            closePanel()
            jump(to: session)
        case .finish(let session):
            finish(session)
        case .reopen(let snapshot, let entry):
            reopenEntry(snapshot: snapshot, entry: entry)
        case .reopenAll(let snapshot):
            reopenAll(snapshot: snapshot)
        case .reopenPin(let entry):
            if let pinned = Pins.load().first(where: { $0.id == entry }) { reopen(pinned) }
        case .reopenLast:
            closePanel()
            reopenLastClosed()
        case .manage:
            closePanel()
            ManageWindowController.shared.show()
        case .saveAndClose:
            closePanel()
            saveAndClose()
        case .saveOnly:
            saveOnly()
        case .installUpdate:
            closePanel()
            installAvailableUpdate()
        case .checkForUpdates:
            closePanel()
            checkForUpdates()
        case .toggleLaunchAtLogin:
            toggleLogin()
        case .toggleHideTitles:
            let hide = !model.hideTitles
            UserDefaults.standard.set(hide, forKey: PanelModel.hideTitlesKey)
            model.hideTitles = hide
            ManageWindowController.shared.settingsChanged()
        case .setLanguage(let language):
            Lang.setting = language
            model.language = language
            ManageWindowController.shared.languageChanged()
        case .clearHistory:
            History.save([])
        case .quit:
            NSApp.terminate(nil)
        }
        model.reload()
        refreshBadge()
    }

    private func refreshBadge() {
        let waiting = waitingSessionCount()
        guard let button = statusItem.button else { return }
        let title = waiting > 0 ? "\(waiting)" : ""
        if button.title != title { button.title = title }
        button.toolTip = waiting == 0 ? "ReTerm"
            : L("ReTerm: \(waiting) Claude session\(waiting == 1 ? " needs" : "s need") you",
                "ReTerm：\(waiting) 个 Claude 会话需要你处理")
    }

    // MARK: Live sessions

    private func jump(to session: LiveSession) {
        switch bringForward(session.jump) {
        case .done:
            break
        case .automationDenied(let app):
            NSApp.activate(ignoringOtherApps: true)
            explainAutomation(app: app, consequence: "")
        case .failed(let message):
            NSApp.activate(ignoringOtherApps: true)
            inform(L("Could not bring that session forward", "没能跳到这个会话"), message)
        }
    }

    private func finish(_ session: LiveSession, anyway: Bool = false) {
        guard model.isFinishable(session) else { return }
        let name = model.shown(session.title, cwd: session.cwd)
        do {
            // Only a session that has finished its turn closes without asking; the check uses the
            // same reading of its status as the step that ends it.
            let result = try finishTerminalSession(sessionId: session.sessionId, allowUnfinished: anyway)
            // Show it moving to Finished straight away; the rescan confirms it once the window has closed.
            model.live.removeAll { $0.sessionId == session.sessionId }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                completeFinish(result)
                self?.model.reload()
                self?.refreshBadge()
            }
        } catch FinishError.notFinished(let status) {
            closePanel()
            NSApp.activate(ignoringOtherApps: true)
            let word = LiveStatus(rawValue: status).map { statusText(LiveSession(
                pid: session.pid, sessionId: session.sessionId, title: session.title, cwd: session.cwd, status: $0,
                waitingFor: session.waitingFor, statusSince: nil, hostKind: session.hostKind, hostLabel: session.hostLabel,
                hostDetail: nil, jump: session.jump)) } ?? status
            let alert = NSAlert()
            alert.messageText = L("“\(name)” is not finished", "“\(name)”还没结束")
            alert.informativeText = L(
                "It is \(word.lowercased()) and will be interrupted. It is kept under Finished, so you can reopen it later.",
                "它现在的状态是“\(word)”，会被中断。它会保存在“完成”里，之后可以重新打开。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Finish Anyway", "仍然完成"))
            alert.addButton(withTitle: L("Cancel", "取消"))
            if alert.runModal() == .alertFirstButtonReturn { finish(session, anyway: true) }
        } catch FinishError.gone {
            closePanel()
            NSApp.activate(ignoringOtherApps: true)
            inform(L("That session has already ended", "这个会话已经结束了"), L("Nothing was saved or closed.", "没有保存或关闭任何东西。"))
        } catch FinishError.automationDenied {
            closePanel()
            NSApp.activate(ignoringOtherApps: true)
            explainAutomation(app: "Terminal", consequence: L("\n\nNothing was closed.", "\n\n没有关闭任何东西。"))
        } catch FinishError.notSaved {
            closePanel()
            NSApp.activate(ignoringOtherApps: true)
            inform(L("The session could not be saved", "没能保存这个会话"), L("Nothing was closed.", "没有关闭任何东西。"))
        } catch {
            closePanel()
            NSApp.activate(ignoringOtherApps: true)
            inform(L("Could not talk to Terminal", "没能和 Terminal 通信"), "\(error)" + L("\n\nNothing was closed.", "\n\n没有关闭任何东西。"))
        }
    }

    // MARK: Updates

    private func checkQuietlyIfDue() {
        let last = UserDefaults.standard.double(forKey: Updater.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Updater.lastCheckKey)
        Updater.fetchLatest { [weak self] result in
            if case .success(let release) = result, Updater.isNewer(release.version, than: Updater.currentVersion) {
                self?.model.update = release
            }
        }
    }

    private func checkForUpdates() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Updater.lastCheckKey)
        Updater.fetchLatest { [weak self] result in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            switch result {
            case .failure(let error):
                self.inform(L("Could not check for updates", "没能检查更新"), error.localizedDescription)
            case .success(let release):
                if Updater.isNewer(release.version, than: Updater.currentVersion) {
                    self.model.update = release
                    self.offer(release)
                } else {
                    self.model.update = nil
                    self.inform(L("ReTerm is up to date", "ReTerm 已是最新版"),
                                L("You have version \(Updater.currentVersion), the latest release.",
                                  "你的版本 \(Updater.currentVersion) 就是最新发布的版本。"))
                }
            }
        }
    }

    private func installAvailableUpdate() {
        guard let release = model.update else { return }
        NSApp.activate(ignoringOtherApps: true)
        offer(release)
    }

    private func offer(_ release: Updater.Release) {
        let alert = NSAlert()
        alert.messageText = L("ReTerm \(release.version) is available", "ReTerm \(release.version) 可以更新了")
        let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = L("You have \(Updater.currentVersion).", "你现在的版本是 \(Updater.currentVersion)。")
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
            + L("\n\nYour saved windows are kept. macOS may ask once more for permission to control Terminal after updating.",
                "\n\n已保存的窗口会保留。更新后 macOS 可能会再问一次是否允许控制 Terminal。")
        alert.addButton(withTitle: L("Update and Relaunch", "更新并重启"))
        alert.addButton(withTitle: L("View on GitHub", "在 GitHub 上查看"))
        alert.addButton(withTitle: L("Later", "以后再说"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Updater.install(release) { [weak self] result in
                switch result {
                case .success(let bundle):
                    Updater.relaunch(bundle)
                case .failure(let error):
                    NSApp.activate(ignoringOtherApps: true)
                    self?.inform(L("Update failed", "更新失败"), error.localizedDescription
                                 + L("\n\nYou can download it from the GitHub page instead.", "\n\n可以改从 GitHub 页面下载。"))
                }
            }
        case .alertSecondButtonReturn:
            if let url = URL(string: release.html_url) { NSWorkspace.shared.open(url) }
        default:
            break
        }
    }

    private func inform(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }

    // MARK: Save, close, reopen

    private func saveOnly() {
        let entries = withBounds(detectTerminalTabs())
        guard !entries.isEmpty else { return }
        if !History.add(Snapshot(closed: false, entries: entries)) {
            closePanel()
            NSApp.activate(ignoringOtherApps: true)
            inform(L("The snapshot could not be saved", "没能保存快照"),
                   L("Check that ~/Library/Application Support/ReTerm is writable.", "请检查 ~/Library/Application Support/ReTerm 是否可写。"))
        }
    }

    private func saveAndClose() {
        let entries = detectTerminalTabs()
        guard !entries.isEmpty else { return }
        let claude = entries.filter { $0.kind == "claude" }
        let busy = claude.filter { ($0.status ?? "idle") != "idle" }
        let codex = entries.filter { $0.kind == "codex" }.count
        let shells = entries.count - claude.count - codex

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Save and close \(entries.count) Terminal tab\(entries.count == 1 ? "" : "s")?",
                              "保存并关闭 \(entries.count) 个 Terminal 标签页？")
        var info = L("\(claude.count) Claude Code session\(claude.count == 1 ? "" : "s"), \(shells) plain shell\(shells == 1 ? "" : "s"). You can reopen each one from ReTerm.",
                     "\(claude.count) 个 Claude Code 会话，\(shells) 个普通 shell。每一个都能在 ReTerm 里重新打开。")
        if codex > 0 {
            info = L("\(codex) Codex session\(codex == 1 ? "" : "s"), ", "\(codex) 个 Codex 会话，") + info
        }
        if !busy.isEmpty {
            info += L("\n\n\(busy.count) Claude session\(busy.count == 1 ? " is" : "s are") still working and will be interrupted:\n",
                      "\n\n有 \(busy.count) 个 Claude 会话还在工作，会被中断：\n")
                + busy.map { "• \(model.shown($0.title, cwd: $0.cwd))" }.joined(separator: "\n")
            alert.alertStyle = .warning
        }
        alert.informativeText = info
        alert.addButton(withTitle: L("Save & Close", "保存并关闭"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Ask Terminal which windows to close before anything is terminated,
        // so a missing Automation permission stops the whole operation.
        let ids: [Int]
        do {
            ids = try windowIds(coveredBy: entries.map(\.tty))
        } catch CloseError.automationDenied {
            explainAutomation(app: "Terminal", consequence: L("\n\nNothing was closed.", "\n\n没有关闭任何东西。"))
            return
        } catch {
            inform(L("Could not talk to Terminal", "没能和 Terminal 通信"), "\(error)" + L("\n\nNothing was closed.", "\n\n没有关闭任何东西。"))
            return
        }

        guard History.add(Snapshot(closed: true, entries: withBounds(entries))) else {
            inform(L("The snapshot could not be saved", "没能保存快照"), L("Nothing was closed.", "没有关闭任何东西。"))
            return
        }
        hangUp(ttys: entries.map(\.tty))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            closeWindows(ids: ids)
        }
    }

    private func explainAutomation(app: String, consequence: String) {
        let alert = NSAlert()
        alert.messageText = L("ReTerm needs permission to control \(app)", "ReTerm 需要控制 \(app) 的权限")
        alert.informativeText = L("Open System Settings › Privacy & Security › Automation and turn on \(app) under ReTerm, then try again.",
                                  "打开“系统设置 › 隐私与安全性 › 自动化”，在 ReTerm 下面打开 \(app)，然后再试一次。") + consequence
        alert.addButton(withTitle: L("Open System Settings", "打开系统设置"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reopenEntry(snapshot sid: UUID, entry eid: UUID) {
        guard let entry = History.load().first(where: { $0.id == sid })?.entries.first(where: { $0.id == eid }) else { return }
        if reopen(entry) { History.markReopened(snapshot: sid, entry: eid) }
    }

    /// The shortcut: brings back the most recently closed entry that has not been reopened yet.
    private func reopenLastClosed() {
        guard let entry = History.lastClosed() else {
            NSSound.beep()
            return
        }
        if reopen(entry) { History.markReopened(entry: entry.id) }
        model.reload()
    }

    private func reopenAll(snapshot sid: UUID) {
        guard let snapshot = History.load().first(where: { $0.id == sid }) else { return }
        for (index, entry) in snapshot.entries.filter({ !$0.reopened }).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.4) { [weak self] in
                if reopen(entry) { History.markReopened(snapshot: sid, entry: entry.id) }
                self?.model.reload()
            }
        }
    }

    private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            closePanel()
            NSApp.activate(ignoringOtherApps: true)
            inform(L("Could not change Launch at Login", "没能更改“登录时启动”"), error.localizedDescription)
        }
    }
}
