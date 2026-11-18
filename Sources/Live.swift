import AppKit
import Foundation

// MARK: - Live Claude Code sessions
//
// Every running interactive Claude Code session on this Mac, wherever its window is
// (Terminal, iTerm2, VS Code and its relatives, the Claude desktop app), read from
// ~/.claude/sessions/<pid>.json. Only the fields below are read: those files also hold
// tokens for Claude Code's own use, which ReTerm never reads or stores.

enum LiveStatus: String, Codable {
    case waiting    // stopped on a permission prompt, a dialog or a question
    case idle       // finished its turn: your move
    case fresh      // started, nothing sent yet
    case busy       // working
    case shell      // the user is running a shell command in it
    case unknown

    /// Menu order: needs you first, then your turn, then working.
    var rank: Int {
        switch self {
        case .waiting: return 0
        case .idle: return 1
        case .busy, .shell: return 2
        case .unknown: return 3
        case .fresh: return 4
        }
    }
}

enum HostKind: String, Codable {
    case terminal, iterm, editor, desktop, remote, tmux, app, unknown
}

/// How a click brings a session's window to the front.
enum Jump: Codable, Equatable {
    case terminal(app: String, tty: String)
    /// `folder` only when it is exactly the folder of an open editor window.
    case editor(appPath: String, cli: String, folder: String?)
    case openApp(path: String)
    /// `fallback` is opened only when nothing can open `url`.
    case url(url: String, fallback: String?)
    case unavailable(reason: String)
}

struct LiveSession: Codable {
    let pid: Int32
    let sessionId: String
    let title: String
    let cwd: String
    let status: LiveStatus
    let waitingFor: String?
    let statusSince: Date?
    let hostKind: HostKind
    /// "Terminal", "VS Code", "Claude App", ...
    let hostLabel: String
    /// Where in the app: the tty, the editor folder.
    let hostDetail: String?
    let jump: Jump
}

// MARK: - Session files

struct SessionRecord {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let nameSource: String?
    let kind: String?
    let entrypoint: String?
    let procStart: String?
    let status: String?
    let waitingFor: String?
    let statusUpdatedAt: Date?
    let bridgeSessionId: String?
    let hostSessionId: String?

    init?(json data: Data) {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawPid = o["pid"] as? Int, let pid = Int32(exactly: rawPid), pid > 0,
              let sessionId = o["sessionId"] as? String, !sessionId.isEmpty else { return nil }
        func str(_ key: String) -> String? { o[key] as? String }
        self.pid = pid
        self.sessionId = sessionId
        cwd = str("cwd") ?? NSHomeDirectory()
        name = str("name")
        nameSource = str("nameSource")
        kind = str("kind")
        entrypoint = str("entrypoint")
        procStart = str("procStart")
        status = str("status")
        waitingFor = str("waitingFor")
        statusUpdatedAt = (o["statusUpdatedAt"] as? Double).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        bridgeSessionId = str("bridgeSessionId")
        hostSessionId = str("hostSessionId")
    }

    /// Background agents and SDK runs write session files too; only sessions someone types into count.
    var isInteractive: Bool { kind == nil || kind == "interactive" }

    /// A name given to the session (by the user or the desktop app), not one Claude Code derived from the folder.
    var userName: String? {
        guard nameSource != "derived", let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return name
    }
}

func sessionRecords() -> [SessionRecord] {
    let files = (try? FileManager.default.contentsOfDirectory(at: Paths.claudeSessions, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }.compactMap { url in
        (try? Data(contentsOf: url)).flatMap(SessionRecord.init(json:))
    }
}

// MARK: - Liveness

/// `ps -o lstart` as Claude Code records it in `procStart`: C locale, UTC.
private let lstartFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
    return f
}()

func squashSpaces(_ s: String) -> String {
    s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

func processStartTime(_ pid: Int32) -> String? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return lstartFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)))
}

func executablePath(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

/// Alive, and the same process that wrote the file (pids get reused): the start time it
/// recorded must match, as Claude Code itself checks. A file without one needs the pid
/// to be running Claude Code at least.
func isLive(_ record: SessionRecord) -> Bool {
    if let recorded = record.procStart {
        guard let actual = processStartTime(record.pid) else { return false }
        return squashSpaces(recorded) == squashSpaces(actual)
    }
    guard let path = executablePath(record.pid) else { return false }
    return (path as NSString).lastPathComponent == "claude" || path.contains("/claude/versions/")
}

/// The live interactive records, one per session.
func liveRecords() -> [SessionRecord] {
    var seen = Set<String>()
    return sessionRecords().filter { $0.isInteractive && isLive($0) && seen.insert($0.sessionId).inserted }
}

/// Cheap enough to run every few seconds: reads only the small session files, no `ps`.
func waitingSessionCount() -> Int {
    liveRecords().filter { $0.status == "waiting" }.count
}

// MARK: - Where each session's window is

struct ProcRow {
    let pid: Int32
    let ppid: Int32
    let tty: String
    let args: String
}

func processRows() -> [Int32: ProcRow] {
    var rows: [Int32: ProcRow] = [:]
    // A UTF-8 locale, or ps escapes non-ASCII bytes (a GUI app started by launchd has no LANG).
    for line in run("/bin/ps", ["-axww", "-o", "pid=,ppid=,tty=,args="], environment: ["LC_ALL": "en_US.UTF-8"]).split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count >= 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
        let args = parts.count > 3 ? parts[3].trimmingCharacters(in: .whitespaces) : ""
        rows[pid] = ProcRow(pid: pid, ppid: ppid, tty: String(parts[2]), args: args)
    }
    return rows
}

func matches(_ text: String, _ pattern: String) -> Bool {
    text.range(of: pattern, options: .regularExpression) != nil
}

func firstCapture(_ text: String, _ pattern: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
          let range = Range(m.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

/// The outermost `.app` a command runs from: `Code Helper.app` inside VS Code maps to VS Code.
func appOf(_ args: String) -> String? { firstCapture(args, #"^(/.*?\.app)/Contents/"#) }

/// Bundles that are no host: the CLI the desktop app ships, the claude-cli:// handler.
private let notAHost = #"/claude-code/[^/]+/[^/]+/claude\.app$|/Claude Code URL Handler\.app$"#
/// iTerm2 3.5+ runs shells under an `iTermServer` that is not inside iTerm.app.
private let itermServer = #"^(/[^\n]*/)?iTermServer[^/\s]*(\s|$)"#
private let remoteControl = #"(^|/)claude(\s+-\S+)*\s+(rc|remote-control)(\s|$)"#
private let tmux = #"^(\S*/)?tmux(:|\s|$)"#

private let knownApps: [(pattern: String, kind: HostKind, label: String)] = [
    (#"/Terminal\.app$"#, .terminal, "Terminal"),
    (#"/iTerm2?\.app$"#, .iterm, "iTerm2"),
    (#"/Visual Studio Code\.app$"#, .editor, "VS Code"),
    (#"/Visual Studio Code - Insiders\.app$"#, .editor, "VS Code Insiders"),
    (#"/Cursor\.app$"#, .editor, "Cursor"),
    (#"/Windsurf\.app$"#, .editor, "Windsurf"),
    (#"/VSCodium\.app$"#, .editor, "VSCodium"),
    (#"/Claude\.app$"#, .desktop, "Claude App"),
]

/// Each VS Code-family editor's command line tool, by label.
private let editorTools = ["VS Code": "code", "VS Code Insiders": "code-insiders", "Cursor": "cursor",
                           "Windsurf": "windsurf", "VSCodium": "codium"]

struct Host {
    var kind: HostKind
    var label: String
    var appPath: String?
    var appPid: Int32?
    /// The session's own terminal, "/dev/ttys001".
    var tty: String?
    /// Under `claude rc` (Remote Control): the rc server's terminal.
    var rcTty: String?
    var isRemote = false
}

func ttyPath(_ tty: String?) -> String? {
    guard let tty, !tty.isEmpty, tty != "??", tty != "-" else { return nil }
    return tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
}

func classifyApp(_ appPath: String) -> (kind: HostKind, label: String) {
    for app in knownApps where matches(appPath, app.pattern) { return (app.kind, app.label) }
    return (.app, ((appPath as NSString).lastPathComponent as NSString).deletingPathExtension)
}

/// Walks a session's parent processes up to the app its window lives in.
func hostOf(pid: Int32, rows: [Int32: ProcRow]) -> Host {
    let me = rows[pid]
    let tty = ttyPath(me?.tty)
    var isRemote = false
    var rcTty: String?
    var current = me.flatMap { rows[$0.ppid] }
    var hops = 0
    while let c = current, hops < 64 {
        hops += 1
        if matches(c.args, remoteControl) {
            isRemote = true
            rcTty = ttyPath(c.tty)
        }
        if matches(c.args, tmux) {
            return Host(kind: .tmux, label: "tmux", tty: tty, rcTty: rcTty, isRemote: isRemote)
        }
        if matches(c.args, itermServer) {
            return Host(kind: .iterm, label: "iTerm2", appPath: "/Applications/iTerm.app", tty: tty, rcTty: rcTty, isRemote: isRemote)
        }
        if let app = appOf(c.args), !matches(app, notAHost) {
            // A helper process runs under its app's main process: climb to the topmost one of the same app.
            var main = c
            var up = 0
            while let parent = rows[main.ppid], parent.pid != main.pid, appOf(parent.args) == app, up < 64 {
                main = parent
                up += 1
            }
            // The bundle path from the kernel is exact; the one parsed from ps text is the fallback.
            let bundle = executablePath(main.pid).flatMap(appOf) ?? app
            let (kind, label) = classifyApp(bundle)
            return Host(kind: kind, label: label, appPath: bundle, appPid: main.pid, tty: tty, rcTty: rcTty, isRemote: isRemote)
        }
        if c.ppid <= 1 { break }
        current = rows[c.ppid]
    }
    return Host(kind: .unknown, label: "Unknown", tty: tty, rcTty: rcTty, isRemote: isRemote)
}

/// One ~/.claude/ide/<port>.lock: which folders one editor window has open.
struct IdeLock {
    let pid: Int32?
    let folders: [String]
}

func ideLocks() -> [IdeLock] {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/ide", isDirectory: true)
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "lock" }.compactMap { url in
        guard let data = try? Data(contentsOf: url),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let pid = (o["pid"] as? Int).flatMap { Int32(exactly: $0) }
        return IdeLock(pid: pid, folders: (o["workspaceFolders"] as? [Any])?.compactMap { $0 as? String } ?? [])
    }
}

/// The open editor folder that holds `cwd`, the deepest one, spelled as the editor holds it:
/// an editor focuses an existing window only for an exact folder match. Multi-root windows
/// are left out, since they are opened by a .code-workspace file no lock names.
func workspaceFolder(for cwd: String, appPid: Int32?, locks: [IdeLock]) -> String? {
    var best: String?
    for lock in locks where lock.folders.count == 1 {
        if let appPid, let pid = lock.pid, pid != appPid { continue }
        let folder = lock.folders[0]
        let inside = cwd == folder || cwd.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
        if inside, folder.count > (best?.count ?? -1) { best = folder }
    }
    return best
}

func jumpFor(_ record: SessionRecord, host: Host, locks: [IdeLock]) -> Jump {
    if host.isRemote && record.entrypoint == "sdk-cli" {
        if let bridge = record.bridgeSessionId, matches(bridge, #"^(cse|session)_[A-Za-z0-9_-]+$"#) {
            let id = bridge.hasPrefix("cse_") ? "session_" + bridge.dropFirst(4) : bridge
            return .url(url: "claude://code/\(id)", fallback: "https://claude.ai/code/\(id)")
        }
        if let rc = host.rcTty { return .terminal(app: "Terminal", tty: rc) }
    }
    switch host.kind {
    case .terminal:
        if let tty = host.tty { return .terminal(app: "Terminal", tty: tty) }
        return .openApp(path: host.appPath ?? "/System/Applications/Utilities/Terminal.app")
    case .iterm:
        if let tty = host.tty { return .terminal(app: "iTerm2", tty: tty) }
        return .openApp(path: host.appPath ?? "/Applications/iTerm.app")
    case .editor:
        let appPath = host.appPath ?? "/Applications/Visual Studio Code.app"
        let cli = "\(appPath)/Contents/Resources/app/bin/\(editorTools[host.label] ?? "code")"
        return .editor(appPath: appPath, cli: cli, folder: workspaceFolder(for: record.cwd, appPid: host.appPid, locks: locks))
    case .desktop:
        if let id = record.hostSessionId, matches(id, #"^local_[A-Za-z0-9-]{1,64}$"#) {
            return .url(url: "claude://code/continue?session=\(id)", fallback: nil)
        }
        if let app = host.appPath { return .openApp(path: app) }
        return .unavailable(reason: L("Could not find the app this session runs in.", "找不到这个会话所在的 App。"))
    case .app:
        if let app = host.appPath { return .openApp(path: app) }
        return .unavailable(reason: L("Could not find the app this session runs in.", "找不到这个会话所在的 App。"))
    case .tmux:
        return .unavailable(reason: L("This session runs inside tmux. Switch to its tmux window.", "这个会话在 tmux 里，切到对应的 tmux 窗口即可。"))
    case .remote, .unknown:
        return .unavailable(reason: L("Could not find the window this session runs in.", "找不到这个会话所在的窗口。"))
    }
}

// MARK: - Scan

func liveStatus(_ record: SessionRecord, transcript: URL?) -> LiveStatus {
    switch record.status {
    case "waiting": return .waiting
    case "busy": return .busy
    case "shell": return .shell
    case "idle":
        // Claude Code writes a transcript only once the first message is sent.
        let size = transcript.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        return size == 0 ? .fresh : .idle
    default: return .unknown
    }
}

/// Every live interactive Claude Code session, in menu order.
func scanLiveSessions(includeTitles: Bool = true) -> [LiveSession] {
    let records = liveRecords()
    guard !records.isEmpty else { return [] }
    let rows = processRows()
    let locks = ideLocks()
    let sessions: [LiveSession] = records.map { r in
        let host = hostOf(pid: r.pid, rows: rows)
        let jump = jumpFor(r, host: host, locks: locks)
        let isRemoteControl = host.isRemote && r.entrypoint == "sdk-cli"
        let transcript = transcriptURL(sessionId: r.sessionId, cwd: r.cwd)
        let folder = (r.cwd as NSString).lastPathComponent
        let title = (includeTitles ? sessionTopic(sessionId: r.sessionId, cwd: r.cwd, userName: r.userName, transcript: transcript) : r.userName)
            ?? r.name.flatMap { $0.isEmpty ? nil : $0 } ?? (folder.isEmpty ? r.cwd : folder)
        var detail: String?
        if isRemoteControl {
            detail = "Remote Control"
        } else if case .editor(_, _, let f) = jump {
            detail = ((f ?? r.cwd) as NSString).lastPathComponent
        } else if host.kind == .terminal || host.kind == .iterm {
            detail = host.tty.map { $0.replacingOccurrences(of: "/dev/", with: "") }
        }
        return LiveSession(pid: r.pid, sessionId: r.sessionId, title: title, cwd: r.cwd,
                           status: liveStatus(r, transcript: transcript),
                           waitingFor: r.status == "waiting" ? r.waitingFor : nil,
                           statusSince: r.statusUpdatedAt,
                           hostKind: isRemoteControl ? .remote : host.kind,
                           hostLabel: isRemoteControl ? "Claude App" : host.label,
                           hostDetail: detail, jump: jump)
    }
    return sortLiveSessions(sessions)
}

/// Needs you first (longest waiting first), then your turn (newest first), then working.
func sortLiveSessions(_ list: [LiveSession]) -> [LiveSession] {
    list.sorted { a, b in
        if a.status.rank != b.status.rank { return a.status.rank < b.status.rank }
        let at = a.statusSince?.timeIntervalSince1970 ?? 0
        let bt = b.statusSince?.timeIntervalSince1970 ?? 0
        return a.status == .waiting ? at < bt : at > bt
    }
}

// MARK: - Wording

private let waitingReasons: [String: (en: String, zh: String)] = [
    "permission prompt": ("Permission request", "权限请求待处理"),
    "dialog open": ("Dialog open", "有对话框待处理"),
    "input needed": ("Input needed", "需要你输入"),
    "sandbox request": ("Sandbox request", "沙盒权限请求"),
    "worker request": ("Approval for a subtask", "子任务等你批准"),
    "goal proposal": ("Goal to confirm", "等你确认目标"),
]

func statusText(_ s: LiveSession) -> String {
    switch s.status {
    case .waiting:
        guard let reason = s.waitingFor else { return L("Needs you", "需要你处理") }
        return waitingReasons[reason].map { L($0.en, $0.zh) } ?? reason
    case .idle: return L("Your turn", "等你回复")
    case .busy: return L("Working", "运行中")
    case .shell: return L("In shell", "在跑终端命令")
    case .fresh: return L("New", "新会话")
    case .unknown: return L("Unknown", "状态未知")
    }
}

/// "just now", "5 min", "3 h", "2 d" (刚刚, 5 分钟, 3 小时, 2 天).
func shortAge(_ since: Date?, now: Date = Date()) -> String? {
    guard let since else { return nil }
    let minutes = Int(max(0, now.timeIntervalSince(since)) / 60)
    if minutes < 1 { return L("just now", "刚刚") }
    if minutes < 60 { return L("\(minutes) min", "\(minutes) 分钟") }
    let hours = minutes / 60
    if hours < 24 { return L("\(hours) h", "\(hours) 小时") }
    return L("\(hours / 24) d", "\(hours / 24) 天")
}

// MARK: - Bringing a window forward

enum JumpOutcome {
    case done
    case automationDenied(app: String)
    case failed(String)
}

private func terminalScript(_ tty: String) -> String {
    """
    set wanted to "\(tty)"
    if not (application "Terminal" is running) then return "missing"
    with timeout of 5 seconds
    tell application "Terminal"
        set found to (every window whose (tty of every tab) contains wanted)
        if (count of found) is 0 then return "missing"
        set w to item 1 of found
        set t to (first tab of w whose tty is wanted)
        if miniaturized of w then set miniaturized of w to false
        set selected of t to true
        set frontmost of w to true
        activate
        set frontmost of w to true
        return "ok"
    end tell
    end timeout
    """
}

/// Everything is addressed through the window's id, since raising a window reorders `windows`.
private func itermScript(_ tty: String) -> String {
    """
    set wanted to "\(tty)"
    if not (application "iTerm2" is running) then return "missing"
    with timeout of 5 seconds
    tell application "iTerm2"
        set wids to id of every window
        repeat with k from 1 to count of wids
            set wid to item k of wids
            set tabCount to count of tabs of window id wid
            repeat with ti from 1 to tabCount
                set sessionCount to count of sessions of tab ti of window id wid
                repeat with si from 1 to sessionCount
                    if tty of session si of tab ti of window id wid is wanted then
                        select window id wid
                        select tab ti of window id wid
                        select session si of tab ti of window id wid
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end repeat
    end tell
    end timeout
    return "missing"
    """
}

func runStatus(_ path: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

private func openApp(_ path: String) {
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
}

/// Brings the session's window to the front. Runs on the main thread; slow steps go to the background.
func bringForward(_ jump: Jump) -> JumpOutcome {
    switch jump {
    case .terminal(let app, let tty):
        // The tty goes into the script text, so it must be exactly a tty path.
        guard matches(tty, #"^/dev/ttys[0-9]{1,5}$"#) else { return .failed("Unexpected terminal name \(tty).") }
        var error: NSDictionary?
        let source = app == "iTerm2" ? itermScript(tty) : terminalScript(tty)
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
            if code == -1743 { return .automationDenied(app: app) }
            return .failed((error?[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(code)")
        }
        if result.stringValue != "ok" {
            // The tab has gone; at least bring the app forward.
            openApp(app == "iTerm2" ? "/Applications/iTerm.app" : "/System/Applications/Utilities/Terminal.app")
        }
        return .done
    case .editor(let appPath, let cli, let folder):
        guard let folder else {
            openApp(appPath)
            return .done
        }
        DispatchQueue.global(qos: .userInitiated).async {
            // The editor's own tool focuses the window holding exactly that folder;
            // `-n` keeps it from ever replacing another window's folder.
            let ok = FileManager.default.isExecutableFile(atPath: cli)
                && runStatus(cli, ["-n", "--skip-add-to-recently-opened", folder]) == 0
            if !ok {
                DispatchQueue.main.async {
                    NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: URL(fileURLWithPath: appPath),
                                            configuration: NSWorkspace.OpenConfiguration())
                }
            }
        }
        return .done
    case .openApp(let path):
        openApp(path)
        return .done
    case .url(let url, let fallback):
        if let u = URL(string: url), NSWorkspace.shared.open(u) { return .done }
        if let fallback, let u = URL(string: fallback), NSWorkspace.shared.open(u) { return .done }
        return .failed("Nothing on this Mac could open \(url).")
    case .unavailable(let reason):
        return .failed(reason)
    }
}
