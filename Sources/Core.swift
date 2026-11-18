import AppKit
import Foundation

// MARK: - Model

struct Entry: Codable {
    var id = UUID()
    var kind: String            // "claude" or "shell"
    var cwd: String
    var tty: String             // e.g. "ttys005"
    var sessionId: String?
    var name: String?
    var status: String?
    var reopened = false

    var title: String {
        let folder = (cwd as NSString).lastPathComponent
        if let name, !name.isEmpty { return name }
        return folder.isEmpty ? cwd : folder
    }

    var shortPath: String { (cwd as NSString).abbreviatingWithTildeInPath }
}

struct Snapshot: Codable {
    var id = UUID()
    var date = Date()
    var closed: Bool            // true = windows were closed, false = snapshot only
    var entries: [Entry]
}

// MARK: - Paths

enum Paths {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("ReTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let history = support.appendingPathComponent("history.json")
    static let launch: URL = {
        let dir = support.appendingPathComponent("launch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let claudeSessions = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)
}

// MARK: - History

enum History {
    static let limit = 15

    static func load() -> [Snapshot] {
        guard let data = try? Data(contentsOf: Paths.history) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Snapshot].self, from: data)) ?? []
    }

    static func save(_ snapshots: [Snapshot]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(snapshots.prefix(limit))) else { return }
        try? data.write(to: Paths.history, options: .atomic)
    }

    static func add(_ snapshot: Snapshot) {
        var all = load()
        all.insert(snapshot, at: 0)
        save(all)
    }

    static func markReopened(snapshot: UUID, entry: UUID) {
        var all = load()
        guard let s = all.firstIndex(where: { $0.id == snapshot }),
              let e = all[s].entries.firstIndex(where: { $0.id == entry }) else { return }
        all[s].entries[e].reopened = true
        save(all)
    }
}

// MARK: - Process helpers

struct Proc {
    let pid: Int32
    let ppid: Int32
    let tty: String
    let comm: String
}

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

func processTable() -> [Proc] {
    run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="]).split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
        return Proc(pid: pid, ppid: ppid, tty: String(parts[2]), comm: String(parts[3]))
    }
}

func workingDirectory(of pid: Int32) -> String? {
    for line in run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", String(pid), "-Fn"]).split(separator: "\n")
    where line.hasPrefix("n") {
        return String(line.dropFirst())
    }
    return nil
}

// MARK: - Detection

struct ClaudeSession: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let status: String?
    let kind: String?
}

func liveClaudeSessions() -> [Int32: ClaudeSession] {
    var result: [Int32: ClaudeSession] = [:]
    let files = (try? FileManager.default.contentsOfDirectory(at: Paths.claudeSessions, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "json" {
        guard let data = try? Data(contentsOf: file),
              let session = try? JSONDecoder().decode(ClaudeSession.self, from: data) else { continue }
        result[session.pid] = session
    }
    return result
}

/// One entry per Terminal.app tab: a Claude Code session if one is running in it, otherwise the shell.
func detectTerminalTabs() -> [Entry] {
    let procs = processTable()
    let terminalPids = Set(procs.filter { $0.comm.hasSuffix("/Terminal.app/Contents/MacOS/Terminal") }.map(\.pid))
    let logins = procs.filter { terminalPids.contains($0.ppid) && $0.tty != "??" }
    let sessions = liveClaudeSessions()
    var children: [Int32: [Proc]] = [:]
    for p in procs { children[p.ppid, default: []].append(p) }

    var entries: [Entry] = []
    for login in logins.sorted(by: { $0.tty < $1.tty }) {
        var descendants: [Proc] = []
        var queue = children[login.pid] ?? []
        while let next = queue.first {
            queue.removeFirst()
            descendants.append(next)
            queue.append(contentsOf: children[next.pid] ?? [])
        }
        if let hit = descendants.first(where: { sessions[$0.pid] != nil }), let s = sessions[hit.pid] {
            entries.append(Entry(kind: "claude", cwd: s.cwd, tty: login.tty,
                                 sessionId: s.sessionId, name: s.name, status: s.status))
        } else if let outer = descendants.first {
            // The innermost process is where the user actually is (e.g. a shell started by a script).
            let inner = descendants.last ?? outer
            let cwd = workingDirectory(of: inner.pid) ?? workingDirectory(of: outer.pid) ?? NSHomeDirectory()
            entries.append(Entry(kind: "shell", cwd: cwd, tty: login.tty))
        }
    }
    return entries
}

// MARK: - Reopen

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func launchScript(for entry: Entry) -> String {
    var lines = ["#!/bin/zsh", "clear"]
    lines.append("if ! cd -- \(shellQuote(entry.cwd)); then")
    lines.append("  echo \"ReTerm: folder no longer exists: \"\(shellQuote(entry.cwd))")
    lines.append("  exec \"${SHELL:-/bin/zsh}\" -l")
    lines.append("fi")
    let validId = entry.sessionId.map { $0.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil } ?? false
    if entry.kind == "claude", let id = entry.sessionId, validId {
        // Interactive shell so the user's own aliases and PATH apply to `claude`.
        lines.append("exec \"${SHELL:-/bin/zsh}\" -lic 'claude --resume \(id); exec \"${SHELL:-/bin/zsh}\" -l'")
    } else {
        lines.append("exec \"${SHELL:-/bin/zsh}\" -l")
    }
    return lines.joined(separator: "\n") + "\n"
}

@discardableResult
func reopen(_ entry: Entry) -> Bool {
    let file = Paths.launch.appendingPathComponent("\(entry.id.uuidString).command")
    do {
        try launchScript(for: entry).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    } catch {
        return false
    }
    let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
    let config = NSWorkspace.OpenConfiguration()
    NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: config)
    return true
}

func cleanLaunchFolder() {
    let files = (try? FileManager.default.contentsOfDirectory(at: Paths.launch, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    let cutoff = Date().addingTimeInterval(-86400)
    for file in files {
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let date, date < cutoff { try? FileManager.default.removeItem(at: file) }
    }
}

// MARK: - Close

enum CloseError: Error {
    case automationDenied
    case script(String)
}

func appleScriptList(_ items: [String]) -> String {
    "{" + items.map { "\"\($0)\"" }.joined(separator: ", ") + "}"
}

/// Returns the ids of Terminal windows whose tabs are all in `ttys`.
func windowIds(coveredBy ttys: [String]) throws -> [Int] {
    let source = """
    set targets to \(appleScriptList(ttys.map { "/dev/" + $0 }))
    set ids to {}
    tell application "Terminal"
        repeat with w in windows
            try
                set tabTtys to tty of every tab of w
                if (count of tabTtys) > 0 then
                    set allIn to true
                    repeat with t in tabTtys
                        if targets does not contain (t as text) then set allIn to false
                    end repeat
                    if allIn then set end of ids to id of w
                end if
            end try
        end repeat
    end tell
    return ids
    """
    var error: NSDictionary?
    guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
        let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -1743 { throw CloseError.automationDenied }
        throw CloseError.script((error?[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(code)")
    }
    var ids: [Int] = []
    if result.numberOfItems > 0 {
        for i in 1...result.numberOfItems {
            if let item = result.atIndex(i) { ids.append(Int(item.int32Value)) }
        }
    }
    return ids
}

func closeWindows(ids: [Int]) {
    guard !ids.isEmpty else { return }
    let source = """
    tell application "Terminal"
        repeat with wid in {\(ids.map(String.init).joined(separator: ", "))}
            try
                close (every window whose id is wid) saving no
            end try
        end repeat
    end tell
    """
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
}

/// Sends SIGHUP to everything running on the given ttys, the same signal Terminal sends when a window closes.
func hangUp(ttys: [String]) {
    let targets = Set(ttys)
    for p in processTable() where targets.contains(p.tty) && p.pid != getpid() {
        kill(p.pid, SIGHUP)
    }
}
