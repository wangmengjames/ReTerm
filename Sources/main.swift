import AppKit

let args = CommandLine.arguments

func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

if args.contains("--list") {
    // Print what would be saved right now. Read-only.
    printJSON(detectTerminalTabs())
    exit(0)
}

if args.contains("--live") {
    // Print every running Claude Code session, as the menu lists them. Read-only.
    printJSON(scanLiveSessions())
    exit(0)
}

if let i = args.firstIndex(of: "--render-panel"), args.count > i + 1 {
    // --render-panel <out.png> [--dark] [--sample] [--zh|--en] : draw the panel to a picture (development aid).
    if args.contains("--zh") { Lang.override = .chinese } else if args.contains("--en") { Lang.override = .english }
    Task { @MainActor in
        let ok = renderPanel(to: args[i + 1], dark: args.contains("--dark"), sample: args.contains("--sample"))
        exit(ok ? 0 : 1)
    }
    RunLoop.main.run()
}

if let i = args.firstIndex(of: "--jump"), args.count > i + 1 {
    // --jump <sessionId> : bring that running session's window to the front, as a menu click does.
    guard let session = scanLiveSessions(includeTitles: false).first(where: { $0.sessionId == args[i + 1] }) else {
        print("error: no running session with that id")
        exit(1)
    }
    switch bringForward(session.jump) {
    case .done:
        // An editor jump finishes in the background and may post its fallback to the main queue.
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        exit(0)
    case .automationDenied(let app):
        print("error: not allowed to control \(app) (System Settings › Privacy & Security › Automation)")
        exit(1)
    case .failed(let message):
        print("error: \(message)")
        exit(1)
    }
}

if let i = args.firstIndex(of: "--finish"), args.count > i + 1 {
    // --finish <sessionId> [--force] : save a Terminal session under Finished and close it, as ⌥-clicking its row does.
    guard let session = scanLiveSessions(includeTitles: false).first(where: { $0.sessionId == args[i + 1] }),
          session.hostKind == .terminal, case .terminal(_, let ttyPath) = session.jump else {
        print("error: no running Terminal session with that id")
        exit(1)
    }
    _ = ttyPath
    do {
        let result = try finishTerminalSession(sessionId: session.sessionId, allowUnfinished: args.contains("--force"))
        Thread.sleep(forTimeInterval: 1.5)
        completeFinish(result)
        print("finished \(result.entry.kind) session in \(result.entry.cwd); "
              + (result.sharedTabTTY.map { "ended it in shared tab \($0)" } ?? "closed windows \(result.windowIds)"))
        exit(0)
    } catch FinishError.notFinished(let status) {
        print("error: the session is \(status); add --force to finish it anyway")
        exit(1)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

if args.contains("--bounds-now") {
    // Print each open Terminal tab's window frame. Read-only.
    do {
        printJSON(try windowBounds())
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

if args.contains("--pins") {
    printJSON(Pins.load())
    exit(0)
}

if let i = args.firstIndex(of: "--codex-sessions") {
    // --codex-sessions [hours] : how many recent Codex terminal sessions can be read (count only). Read-only.
    let hours = args.count > i + 1 ? Double(args[i + 1]) ?? 24 : 24
    let found = Codex.sessions(modifiedSince: Date().addingTimeInterval(-hours * 3600))
    let named = found.filter { Codex.topic(sessionId: $0.id) != nil }.count
    print("\(found.count) Codex sessions in the last \(Int(hours)) h, \(named) with a name")
    exit(0)
}

if let i = args.firstIndex(of: "--track"), args.count > i + 1 {
    // --track <seconds> : run only the tracker for a while, then stop (development aid).
    Tracker.shared.onRecorded = { print("recorded a closed session") }
    Tracker.shared.start()
    RunLoop.main.run(until: Date().addingTimeInterval(Double(args[i + 1]) ?? 10))
    exit(0)
}

if args.contains("--self-test") {
    // Exercises history and pins in a scratch data folder. Refuses to touch the real one.
    guard ProcessInfo.processInfo.environment["RETERM_HOME"]?.isEmpty == false else {
        print("error: set RETERM_HOME to an empty scratch folder first")
        exit(1)
    }
    var failures = 0
    func check(_ ok: Bool, _ what: String) {
        print((ok ? "ok   " : "FAIL ") + what)
        if !ok { failures += 1 }
    }
    History.save([])
    let a = Entry(kind: "claude", cwd: "/tmp/a", tty: "ttys001", sessionId: "aaa-1", topic: "First", bounds: [1, 2, 300, 400])
    let b = Entry(kind: "codex", cwd: "/tmp/b", tty: "ttys002", sessionId: "bbb-2", topic: "Second")
    let c = Entry(kind: "shell", cwd: "/tmp/c", tty: "ttys003")
    check(History.add(Snapshot(closed: false, entries: [c])), "snapshot-only group saved")
    check(History.lastClosed() == nil, "a snapshot that closed nothing is not 'last closed'")
    check(History.add(Snapshot(closed: true, entries: [a, b])), "closed group saved")
    check(History.addFinished(c), "finished entry saved")
    check(History.load().count == 3, "three groups stored")
    check(History.load().flatMap(\.entries).first { $0.id == a.id }?.bounds == [1, 2, 300, 400], "window frame survives a save")
    check(History.lastClosed()?.id == c.id, "last closed is the newest entry")
    History.markReopened(entry: c.id)
    check(History.lastClosed()?.id == a.id, "after reopening it, the next one is last closed")
    check(History.delete(entry: a.id), "delete one entry")
    check(History.lastClosed()?.id == b.id, "deleted entry is gone")
    check(History.delete(entry: b.id) && History.load().count == 2, "a group is removed once empty")
    check(Pins.load().isEmpty, "no pins to start with")
    check(Pins.toggle(a) && Pins.contains(a), "pin")
    check(Pins.toggle(b) && Pins.load().count == 2, "pin a second")
    check(Pins.load().first?.id != a.id, "a pin is its own copy")
    check(Pins.toggle(a) && !Pins.contains(a) && Pins.load().count == 1, "unpin")
    check(a.pinKey == "claude:aaa-1" && c.pinKey == "shell:/tmp/c", "pin keys")
    let f = [100, 100, 700, 500]
    let inside: ([Int]) -> Bool = { $0[2] <= 1000 && $0[3] <= 800 }
    check(Placement.freeFrame(f, occupied: [], fits: inside) == f, "a free saved frame is used as it is")
    check(Placement.freeFrame(f, occupied: [f], fits: inside) == [124, 124, 724, 524], "an occupied frame is shifted")
    check(Placement.freeFrame(f, occupied: [f, [124, 124, 724, 524]], fits: inside) == [148, 148, 748, 548], "and shifted again past the next window")
    check(Placement.freeFrame([400, 400, 990, 790], occupied: [[400, 400, 990, 790]], fits: inside) == nil, "no shift that would leave the screen")
    check(Placement.freeFrame([400, 400, 2000, 2000], occupied: [], fits: inside) == [400, 400, 2000, 2000], "a free saved frame is kept even if it is large")

    let u1 = "0199aaaa-bbbb-7ccc-8ddd-eeeeeeeeeeee", u2 = "0199aaaa-bbbb-7ccc-8ddd-ffffffffffff", u3 = "0199aaaa-bbbb-7ccc-8ddd-000000000003"
    check(Codex.resumedId(inArguments: "node /x/codex.js resume \(u1)") == u1, "codex resume <id> is read from the command line")
    check(Codex.resumedId(inArguments: "/x/bin/codex resume --last") == nil && Codex.resumedId(inArguments: "/x/bin/codex") == nil,
          "no id without one on the command line")
    let t = Date(timeIntervalSince1970: 1_800_000_000)
    func proc(_ pid: Int32, _ start: Double, cwd: String = "/p", resume: String? = nil, open: String? = nil) -> Codex.Running {
        Codex.Running(pid: pid, cwd: cwd, started: t.addingTimeInterval(start), resumeId: resume, openId: open)
    }
    func sess(_ id: String, created: Double, modified: Double, cwd: String = "/p") -> Codex.Session {
        Codex.Session(id: id, cwd: cwd, created: t.addingTimeInterval(created), modified: t.addingTimeInterval(modified))
    }
    check(Codex.match([proc(1, 0)], sessions: [sess(u1, created: 60, modified: 90)]) == [1: u1], "one tab, its own new session")
    check(Codex.match([proc(1, 0)], sessions: []) == [:], "a tab with nothing sent yet has no session")
    check(Codex.match([proc(1, 0)], sessions: [sess(u1, created: 60, modified: 90, cwd: "/other")]) == [:], "a session in another folder is not taken")
    check(Codex.match([proc(1, 0)], sessions: [sess(u2, created: 300, modified: 400), sess(u1, created: 60, modified: 90)]) == [1: u2],
          "after /new, the newer session")
    check(Codex.match([proc(1, 0, resume: u1)], sessions: []) == [1: u1], "a resumed tab that has not been typed in keeps its id")
    check(Codex.match([proc(1, 0, resume: u1)], sessions: [sess(u2, created: 300, modified: 400)]) == [1: u2],
          "a resumed tab that then did /new shows the new session")
    check(Codex.match([proc(1, 0, resume: u1), proc(2, 100)], sessions: [sess(u2, created: 160, modified: 500)]) == [1: u1, 2: u2],
          "an idle resumed tab does not take its neighbour's session")
    check(Codex.match([proc(1, 0), proc(2, 600)], sessions: [sess(u2, created: 660, modified: 900), sess(u1, created: 60, modified: 800)]) == [1: u1, 2: u2],
          "two plain tabs opened one after the other each get their own")
    check(Codex.match([proc(1, 0), proc(2, 10)], sessions: [sess(u2, created: 80, modified: 900), sess(u1, created: 60, modified: 800)]) == [:],
          "two plain tabs that cannot be told apart get none, rather than a guess")
    check(Codex.match([proc(1, 0, resume: u3), proc(2, 10, resume: u3)], sessions: []) == [1: u3],
          "two tabs never share a session, even when both were started to resume it")
    check(Codex.match([proc(1, 0, open: u1), proc(2, 10)], sessions: [sess(u2, created: 80, modified: 900), sess(u1, created: 60, modified: 800)]) == [1: u1, 2: u2],
          "an open session file settles it")
    check(Codex.match([proc(1, 100)], sessions: [sess(u1, created: -5000, modified: 200)]) == [1: u1], "an older session picked inside the tab")
    check(Codex.match([proc(1, 100), proc(2, 110)], sessions: [sess(u1, created: -5000, modified: 200)]) == [:],
          "but not when two tabs could have picked it")
    let probe = Paths.support.appendingPathComponent("open-file-probe.jsonl")
    FileManager.default.createFile(atPath: probe.path, contents: Data("x".utf8))
    let held = try? FileHandle(forReadingFrom: probe)
    check(Codex.openFiles(of: getpid()).contains { $0.hasSuffix("/open-file-probe.jsonl") }, "open files of a process can be listed")
    try? held?.close()
    History.save([])
    let day = Date(timeIntervalSince1970: 1_800_000_000)
    let s1 = Entry(kind: "claude", cwd: "/tmp/a", tty: "ttys001", sessionId: "sess-1", topic: "One")
    let s2 = Entry(kind: "claude", cwd: "/tmp/b", tty: "ttys002", sessionId: "sess-2", topic: "Two")
    check(History.addFinished(s1, now: day.addingTimeInterval(-90_000)), "a session finished the day before")
    check(History.addClosedAutomatically(s2, at: day), "a session that ended by itself is saved")
    check(History.addClosedAutomatically(Entry(kind: "claude", cwd: "/tmp/a", tty: "ttys009", sessionId: "sess-1", topic: "One again"), at: day.addingTimeInterval(60)),
          "the earlier session ends again")
    let groups = History.load()
    check(groups.count == 1 && groups[0].auto == true && groups[0].entries.count == 2, "both are in one Closed group for the day")
    check(groups[0].entries.first?.topic == "One again" && groups.flatMap(\.entries).filter { $0.sessionId == "sess-1" }.count == 1,
          "a session is listed once, in its newest record")
    check(History.addClosedAutomatically(s2, at: day.addingTimeInterval(-200_000)) && History.load().last?.entries.first?.sessionId == "sess-2",
          "a session recovered from before is filed under its own day")
    check(History.lastClosed()?.sessionId == "sess-1", "a session closed by hand is what the shortcut reopens")
    // An old history file without the newer fields must still load.
    let old = #"[{"id":"7F2C1D7E-0000-4000-8000-000000000001","date":"2026-11-18T10:00:00Z","closed":true,"entries":[{"id":"7F2C1D7E-0000-4000-8000-000000000002","kind":"claude","cwd":"/tmp/x","tty":"ttys009","sessionId":"old-1","reopened":false}]}]"#
    try? old.write(to: Paths.history, atomically: true, encoding: .utf8)
    check(History.load().first?.entries.first?.sessionId == "old-1", "history written by 0.1.0 still loads")
    try? "not json".write(to: Paths.history, atomically: true, encoding: .utf8)
    check(History.load().isEmpty, "unreadable history reads as empty")
    let aside = (try? FileManager.default.contentsOfDirectory(atPath: Paths.support.path))?.contains { $0.hasPrefix("history.unreadable-") } ?? false
    check(aside, "unreadable history is set aside, not overwritten")
    print(failures == 0 ? "all passed" : "\(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

if args.contains("--history") {
    printJSON(History.loadFillingTopics())
    exit(0)
}

if let i = args.firstIndex(of: "--print-script"), args.count > i + 2 {
    // --print-script <cwd> <sessionId|-> : show the launch script without running it.
    // Add --codex for a Codex session.
    let id = args[i + 2] == "-" ? nil : args[i + 2]
    let kind = args.contains("--codex") ? "codex" : (id == nil ? "shell" : "claude")
    print(launchScript(for: Entry(kind: kind, cwd: args[i + 1], tty: "", sessionId: id)), terminator: "")
    exit(0)
}

if let i = args.firstIndex(of: "--open-shell"), args.count > i + 1 {
    // --open-shell <cwd> [--bounds left,top,right,bottom] : open one new Terminal window in that folder.
    var entry = Entry(kind: "shell", cwd: args[i + 1], tty: "")
    if let b = args.firstIndex(of: "--bounds"), args.count > b + 1 {
        entry.bounds = args[b + 1].split(separator: ",").compactMap { Int($0) }
    }
    let ok = reopen(entry)
    // Placing the window waits for the new tab to report its tty.
    RunLoop.main.run(until: Date().addingTimeInterval(entry.bounds == nil ? 1 : 5))
    exit(ok ? 0 : 1)
}

if let i = args.firstIndex(of: "--close-tty"), args.count > i + 1 {
    // --close-tty <ttysNNN> : close one tab's window, using the same steps as the menu command.
    let tty = args[i + 1]
    do {
        let ids = try windowIds(coveredBy: [tty])
        print("window ids: \(ids)")
        hangUp(ttys: [tty])
        Thread.sleep(forTimeInterval: 1.5)
        closeWindows(ids: ids)
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

if args.contains("--check-update") || args.contains("--self-update") {
    // --check-update : print the latest released version. --self-update : install it over this bundle.
    Updater.fetchLatest { result in
        switch result {
        case .failure(let error):
            print("error: \(error.localizedDescription)")
            exit(1)
        case .success(let release):
            let newer = Updater.isNewer(release.version, than: Updater.currentVersion)
            print("current \(Updater.currentVersion), latest \(release.version), newer: \(newer)")
            guard newer, args.contains("--self-update") else { exit(0) }
            Updater.install(release) { outcome in
                switch outcome {
                case .success(let bundle): print("installed \(release.version) at \(bundle.path)"); exit(0)
                case .failure(let error): print("error: \(error.localizedDescription)"); exit(1)
                }
            }
        }
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Never drawn (the app has no menu bar of its own), but it is what makes ⌘V, ⌘A, ⌘W and the
// rest work in the Search & Manage window.
let mainMenu = NSMenu()
let editItem = NSMenuItem()
mainMenu.addItem(editItem)
let edit = NSMenu(title: "Edit")
editItem.submenu = edit
edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
edit.addItem(.separator())
edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
edit.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
edit.addItem(.separator())
edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
app.mainMenu = mainMenu
app.run()
