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
    if session.status != .idle && session.status != .fresh && !args.contains("--force") {
        print("error: the session is \(statusText(session).lowercased()); add --force to finish it anyway")
        exit(1)
    }
    do {
        let result = try finishTerminalSession(tty: ttyPath.replacingOccurrences(of: "/dev/", with: ""), sessionId: session.sessionId)
        Thread.sleep(forTimeInterval: 1.5)
        closeWindows(ids: result.windowIds)
        print("finished \(result.entry.kind) session in \(result.entry.cwd); closed windows \(result.windowIds)")
        exit(0)
    } catch {
        print("error: \(error)")
        exit(1)
    }
}

if args.contains("--history") {
    printJSON(History.loadFillingTopics())
    exit(0)
}

if let i = args.firstIndex(of: "--print-script"), args.count > i + 2 {
    // --print-script <cwd> <sessionId|-> : show the launch script without running it.
    let id = args[i + 2] == "-" ? nil : args[i + 2]
    print(launchScript(for: Entry(kind: id == nil ? "shell" : "claude", cwd: args[i + 1], tty: "", sessionId: id)), terminator: "")
    exit(0)
}

if let i = args.firstIndex(of: "--open-shell"), args.count > i + 1 {
    // --open-shell <cwd> : open one new Terminal window in that folder.
    let ok = reopen(Entry(kind: "shell", cwd: args[i + 1], tty: ""))
    Thread.sleep(forTimeInterval: 1)
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
app.run()
