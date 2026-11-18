import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let relative = RelativeDateTimeFormatter()
    private var availableUpdate: Updater.Release?
    private var updateTimer: Timer?
    private var badgeTimer: Timer?
    /// The live sessions the open menu shows, by session id, for the click handler.
    private var shownLive: [String: LiveSession] = [:]
    private static let hideTitlesKey = "hideSessionTitles"
    private var hideTitles: Bool { UserDefaults.standard.bool(forKey: Self.hideTitlesKey) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.uturn.backward.square",
                                           accessibilityDescription: "ReTerm")
        statusItem.button?.imagePosition = .imageLeft
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        cleanLaunchFolder()

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

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if let update = availableUpdate {
            let i = item("Update to ReTerm \(update.version)…", #selector(installAvailableUpdate))
            i.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Update")
            menu.addItem(i)
            menu.addItem(.separator())
        }
        addLiveSessions(to: menu)
        menu.addItem(.separator())

        let open = detectTerminalTabs(includeTopics: false)

        let close = item("Save & Close All Terminal Windows (\(open.count))…", #selector(saveAndClose))
        close.isEnabled = !open.isEmpty
        menu.addItem(close)
        let save = item("Save Snapshot Only", #selector(saveOnly))
        save.isEnabled = !open.isEmpty
        menu.addItem(save)
        menu.addItem(.separator())

        let history = History.loadFillingTopics()
        if let latest = history.first {
            addSnapshot(latest, to: menu)
            if history.count > 1 {
                let earlier = NSMenuItem(title: "Earlier", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for snapshot in history.dropFirst() {
                    let entry = NSMenuItem(title: heading(snapshot), action: nil, keyEquivalent: "")
                    let inner = NSMenu()
                    inner.autoenablesItems = false
                    addSnapshot(snapshot, to: inner, withHeading: false)
                    entry.submenu = inner
                    sub.addItem(entry)
                }
                earlier.submenu = sub
                menu.addItem(earlier)
            }
        } else {
            let empty = NSMenuItem(title: "Nothing saved yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }

        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let hide = item("Hide Session Titles", #selector(toggleHideTitles))
        hide.state = hideTitles ? .on : .off
        hide.toolTip = "Show folder names instead of session titles, e.g. while sharing your screen."
        menu.addItem(hide)
        let clear = item("Clear History", #selector(clearHistory))
        clear.isEnabled = !history.isEmpty
        menu.addItem(clear)
        menu.addItem(.separator())
        let version = NSMenuItem(title: "ReTerm \(Updater.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)
        menu.addItem(item("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(item("Quit ReTerm", #selector(quit)))
    }

    // MARK: Live sessions

    private func refreshBadge() {
        let waiting = waitingSessionCount()
        guard let button = statusItem.button else { return }
        let title = waiting > 0 ? "\(waiting)" : ""
        if button.title != title { button.title = title }
        button.toolTip = waiting == 0 ? "ReTerm"
            : "ReTerm: \(waiting) Claude session\(waiting == 1 ? " needs" : "s need") you"
    }

    /// A title, or its folder's name while titles are hidden.
    private func shown(_ title: String, cwd: String) -> String {
        guard hideTitles else { return title }
        let folder = (cwd as NSString).lastPathComponent
        return folder.isEmpty ? cwd : folder
    }

    private func addLiveSessions(to menu: NSMenu) {
        let live = scanLiveSessions(includeTitles: !hideTitles)
        shownLive = Dictionary(live.map { ($0.sessionId, $0) }, uniquingKeysWith: { a, _ in a })
        refreshBadge()
        let head = NSMenuItem(title: live.isEmpty ? "No Claude Code sessions running" : "Claude Code Sessions (\(live.count))",
                              action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        let now = Date()
        for session in live {
            let place = [session.hostLabel, session.hostDetail].compactMap { $0 }.joined(separator: " ")
            let details = [statusText(session), place] + [shortAge(session.statusSince, now: now)].compactMap { $0 }
            let i = item("\(shown(session.title, cwd: session.cwd))  —  \(details.joined(separator: " · "))",
                         #selector(jumpToSession(_:)))
            i.image = statusImage(session.status)
            i.representedObject = session.sessionId
            if case .unavailable(let reason) = session.jump {
                i.isEnabled = false
                i.toolTip = reason
            } else {
                i.toolTip = "Bring this session's window to the front (\(session.cwd))"
            }
            // Holding ⌥ turns the row into "finished": save it under Finished and close its window.
            i.keyEquivalentModifierMask = []
            menu.addItem(i)
            menu.addItem(finishItem(for: session))
        }
        if !live.isEmpty { menu.addItem(finishMenu(for: live)) }
    }

    /// Only a Terminal session can be closed and later resumed with `claude --resume`.
    private func isFinishable(_ session: LiveSession) -> Bool {
        guard session.hostKind == .terminal, case .terminal(let app, _) = session.jump else { return false }
        return app == "Terminal"
    }

    /// "Mark as Finished ▸": every Terminal session, one click each. Visible, no key to hold.
    private func finishMenu(for live: [LiveSession]) -> NSMenuItem {
        let parent = NSMenuItem(title: "Mark as Finished", action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Mark as Finished")
        let sub = NSMenu()
        sub.autoenablesItems = false
        let finishable = live.filter(isFinishable)
        for session in finishable {
            let i = item("\(shown(session.title, cwd: session.cwd))  —  \(statusText(session))", #selector(finishSession(_:)))
            i.image = statusImage(session.status)
            i.representedObject = session.sessionId
            i.toolTip = "Close this session's window and keep it under Finished, ready to reopen."
            sub.addItem(i)
        }
        if finishable.isEmpty {
            let none = NSMenuItem(title: "No Terminal sessions to finish", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        }
        sub.addItem(.separator())
        let note = NSMenuItem(title: "Saves it under Finished and closes its window", action: nil, keyEquivalent: "")
        note.isEnabled = false
        sub.addItem(note)
        if finishable.count < live.count {
            let other = NSMenuItem(title: "Sessions in other apps can’t be closed from here", action: nil, keyEquivalent: "")
            other.isEnabled = false
            sub.addItem(other)
        }
        parent.submenu = sub
        return parent
    }

    private func finishItem(for session: LiveSession) -> NSMenuItem {
        let name = shown(session.title, cwd: session.cwd)
        let finish: NSMenuItem
        if isFinishable(session) {
            finish = item("Finished: Save & Close “\(name)”", #selector(finishSession(_:)))
            finish.representedObject = session.sessionId
            finish.toolTip = "Close this session's window and keep it under Finished, ready to reopen."
        } else {
            finish = NSMenuItem(title: "\(name)  —  only Terminal sessions can be finished here", action: nil, keyEquivalent: "")
            finish.isEnabled = false
        }
        finish.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: "Finished")
        finish.keyEquivalentModifierMask = .option
        finish.isAlternate = true
        return finish
    }

    @objc private func finishSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let session = shownLive[id],
              case .terminal(_, let ttyPath) = session.jump else { return }
        let tty = ttyPath.replacingOccurrences(of: "/dev/", with: "")
        let name = shown(session.title, cwd: session.cwd)
        // Only a session that has finished its turn closes without asking.
        let current = scanLiveSessions(includeTitles: false).first(where: { $0.sessionId == id })
        if let current, current.status != .idle && current.status != .fresh {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "“\(name)” is not finished"
            alert.informativeText = "It is \(statusText(current).lowercased()) and will be interrupted. It is kept under Finished, so you can reopen it later."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Finish Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            let result = try finishTerminalSession(tty: tty, sessionId: id)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                closeWindows(ids: result.windowIds)
            }
        } catch FinishError.gone {
            NSApp.activate(ignoringOtherApps: true)
            inform("That session has already ended", "Nothing was saved or closed.")
        } catch FinishError.automationDenied {
            NSApp.activate(ignoringOtherApps: true)
            explainAutomation(app: "Terminal", consequence: "\n\nNothing was closed.")
        } catch FinishError.notSaved {
            NSApp.activate(ignoringOtherApps: true)
            inform("The session could not be saved", "Nothing was closed.")
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            inform("Could not talk to Terminal", "\(error)\n\nNothing was closed.")
        }
    }

    private func statusImage(_ status: LiveStatus) -> NSImage? {
        let (symbol, color): (String, NSColor) = {
            switch status {
            case .waiting: return ("exclamationmark.circle.fill", .systemOrange)
            case .idle: return ("checkmark.circle.fill", .systemGreen)
            case .busy: return ("circle.dotted", .systemBlue)
            case .shell: return ("terminal", .systemTeal)
            case .fresh: return ("circle", .secondaryLabelColor)
            case .unknown: return ("questionmark.circle", .secondaryLabelColor)
            }
        }()
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        return NSImage(systemSymbolName: symbol, accessibilityDescription: status.rawValue)?.withSymbolConfiguration(config)
    }

    @objc private func jumpToSession(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let session = shownLive[id] else { return }
        switch bringForward(session.jump) {
        case .done:
            break
        case .automationDenied(let app):
            NSApp.activate(ignoringOtherApps: true)
            explainAutomation(app: app, consequence: "")
        case .failed(let message):
            NSApp.activate(ignoringOtherApps: true)
            inform("Could not bring that session forward", message)
        }
    }

    @objc private func toggleHideTitles() {
        UserDefaults.standard.set(!hideTitles, forKey: Self.hideTitlesKey)
    }

    // MARK: Updates

    private func checkQuietlyIfDue() {
        let last = UserDefaults.standard.double(forKey: Updater.lastCheckKey)
        guard Date().timeIntervalSince1970 - last > 86400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Updater.lastCheckKey)
        Updater.fetchLatest { [weak self] result in
            if case .success(let release) = result, Updater.isNewer(release.version, than: Updater.currentVersion) {
                self?.availableUpdate = release
            }
        }
    }

    @objc private func checkForUpdates() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Updater.lastCheckKey)
        Updater.fetchLatest { [weak self] result in
            guard let self else { return }
            NSApp.activate(ignoringOtherApps: true)
            switch result {
            case .failure(let error):
                self.inform("Could not check for updates", error.localizedDescription)
            case .success(let release):
                if Updater.isNewer(release.version, than: Updater.currentVersion) {
                    self.availableUpdate = release
                    self.offer(release)
                } else {
                    self.availableUpdate = nil
                    self.inform("ReTerm is up to date", "You have version \(Updater.currentVersion), the latest release.")
                }
            }
        }
    }

    @objc private func installAvailableUpdate() {
        guard let release = availableUpdate else { return }
        NSApp.activate(ignoringOtherApps: true)
        offer(release)
    }

    private func offer(_ release: Updater.Release) {
        let alert = NSAlert()
        alert.messageText = "ReTerm \(release.version) is available"
        let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = "You have \(Updater.currentVersion)."
            + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(600)))
            + "\n\nYour saved windows are kept. macOS may ask once more for permission to control Terminal after updating."
        alert.addButton(withTitle: "Update and Relaunch")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Updater.install(release) { [weak self] result in
                switch result {
                case .success(let bundle):
                    Updater.relaunch(bundle)
                case .failure(let error):
                    NSApp.activate(ignoringOtherApps: true)
                    self?.inform("Update failed", error.localizedDescription + "\n\nYou can download it from the GitHub page instead.")
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

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    private func heading(_ snapshot: Snapshot) -> String {
        if snapshot.finished == true {
            let day = Calendar.current.isDateInToday(snapshot.date) ? "today"
                : DateFormatter.localizedString(from: snapshot.date, dateStyle: .medium, timeStyle: .none)
            return "Finished \(day) (\(snapshot.entries.count))"
        }
        let when = relative.localizedString(for: snapshot.date, relativeTo: Date())
        return "\(snapshot.closed ? "Closed" : "Saved") \(when) (\(snapshot.entries.count))"
    }

    private func addSnapshot(_ snapshot: Snapshot, to menu: NSMenu, withHeading: Bool = true) {
        if withHeading {
            let head = NSMenuItem(title: heading(snapshot), action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
        }
        for entry in snapshot.entries {
            let i = item("\(shown(entry.title, cwd: entry.cwd))  —  \(entry.shortPath)", #selector(reopenEntry(_:)))
            i.image = NSImage(systemSymbolName: entry.kind == "claude" ? "sparkles" : "terminal",
                              accessibilityDescription: entry.kind)
            i.state = entry.reopened ? .on : .off
            i.toolTip = entry.kind == "claude"
                ? "Resume Claude Code session \(hideTitles ? "" : entry.name ?? "") (\(entry.sessionId ?? "")) in \(entry.cwd)"
                : "Open a shell in \(entry.cwd)"
            i.representedObject = [snapshot.id.uuidString, entry.id.uuidString]
            menu.addItem(i)
        }
        let remaining = snapshot.entries.filter { !$0.reopened }.count
        let all = item("Reopen All Not Yet Reopened (\(remaining))", #selector(reopenAll(_:)))
        all.representedObject = snapshot.id.uuidString
        all.isEnabled = remaining > 0
        menu.addItem(all)
    }

    // MARK: Actions

    @objc private func saveOnly() {
        let entries = detectTerminalTabs()
        guard !entries.isEmpty else { return }
        if !History.add(Snapshot(closed: false, entries: entries)) {
            NSApp.activate(ignoringOtherApps: true)
            inform("The snapshot could not be saved", "Check that ~/Library/Application Support/ReTerm is writable.")
        }
    }

    @objc private func saveAndClose() {
        let entries = detectTerminalTabs()
        guard !entries.isEmpty else { return }
        let claude = entries.filter { $0.kind == "claude" }
        let busy = claude.filter { ($0.status ?? "idle") != "idle" }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Save and close \(entries.count) Terminal tab\(entries.count == 1 ? "" : "s")?"
        var info = "\(claude.count) Claude Code session\(claude.count == 1 ? "" : "s"), \(entries.count - claude.count) plain shell\(entries.count - claude.count == 1 ? "" : "s"). You can reopen each one from the ReTerm menu."
        if !busy.isEmpty {
            info += "\n\n\(busy.count) Claude session\(busy.count == 1 ? " is" : "s are") still working and will be interrupted:\n"
                + busy.map { "• \(shown($0.title, cwd: $0.cwd))" }.joined(separator: "\n")
            alert.alertStyle = .warning
        }
        alert.informativeText = info
        alert.addButton(withTitle: "Save & Close")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Ask Terminal which windows to close before anything is terminated,
        // so a missing Automation permission stops the whole operation.
        let ids: [Int]
        do {
            ids = try windowIds(coveredBy: entries.map(\.tty))
        } catch CloseError.automationDenied {
            explainAutomation(app: "Terminal", consequence: "\n\nNothing was closed.")
            return
        } catch {
            let failed = NSAlert()
            failed.messageText = "Could not talk to Terminal"
            failed.informativeText = "\(error)\n\nNothing was closed."
            failed.runModal()
            return
        }

        guard History.add(Snapshot(closed: true, entries: entries)) else {
            inform("The snapshot could not be saved", "Nothing was closed.")
            return
        }
        hangUp(ttys: entries.map(\.tty))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            closeWindows(ids: ids)
        }
    }

    private func explainAutomation(app: String, consequence: String) {
        let alert = NSAlert()
        alert.messageText = "ReTerm needs permission to control \(app)"
        alert.informativeText = "Open System Settings › Privacy & Security › Automation and turn on \(app) under ReTerm, then try again." + consequence
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func reopenEntry(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [String],
              let sid = UUID(uuidString: ids[0]), let eid = UUID(uuidString: ids[1]),
              let entry = History.load().first(where: { $0.id == sid })?.entries.first(where: { $0.id == eid })
        else { return }
        if reopen(entry) { History.markReopened(snapshot: sid, entry: eid) }
    }

    @objc private func reopenAll(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let sid = UUID(uuidString: raw),
              let snapshot = History.load().first(where: { $0.id == sid }) else { return }
        for (index, entry) in snapshot.entries.filter({ !$0.reopened }).enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.4) {
                if reopen(entry) { History.markReopened(snapshot: sid, entry: entry.id) }
            }
        }
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func clearHistory() { History.save([]) }

    @objc private func quit() { NSApp.terminate(nil) }
}
