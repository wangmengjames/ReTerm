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
    /// What the session is about (Claude Code's own window title). nil = not looked up yet, "" = none found.
    var topic: String?

    var title: String {
        let folder = (cwd as NSString).lastPathComponent
        if let topic, !topic.isEmpty { return topic }
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
    /// Sessions marked finished one at a time from the live list, collected per day.
    var finished: Bool? = nil
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
        do {
            return try decoder.decode([Snapshot].self, from: data)
        } catch {
            // Unreadable history: set it aside so the next save cannot overwrite it.
            let aside = Paths.support.appendingPathComponent("history.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Paths.history, to: aside)
            return []
        }
    }

    /// Returns false if the history could not be written.
    @discardableResult
    static func save(_ snapshots: [Snapshot]) -> Bool {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(Array(snapshots.prefix(limit))) else { return false }
        do {
            try data.write(to: Paths.history, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func add(_ snapshot: Snapshot) -> Bool {
        var all = load()
        all.insert(snapshot, at: 0)
        return save(all)
    }

    /// Fills in missing session topics (for snapshots saved before topics existed) and stores them.
    static func loadFillingTopics() -> [Snapshot] {
        var all = load()
        var changed = false
        for s in all.indices {
            for e in all[s].entries.indices where all[s].entries[e].kind == "claude" && all[s].entries[e].topic == nil {
                let entry = all[s].entries[e]
                all[s].entries[e].topic = entry.sessionId.flatMap { sessionTopic(sessionId: $0, cwd: entry.cwd) } ?? ""
                changed = true
            }
        }
        if changed { save(all) }
        return all
    }

    /// Adds a session marked finished to today's Finished group, or starts one.
    @discardableResult
    static func addFinished(_ entry: Entry, now: Date = Date()) -> Bool {
        var all = load()
        if let first = all.first, first.finished == true, Calendar.current.isDate(first.date, inSameDayAs: now) {
            all[0].entries.insert(entry, at: 0)
            all[0].date = now
        } else {
            all.insert(Snapshot(date: now, closed: true, entries: [entry], finished: true), at: 0)
        }
        return save(all)
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
func run(_ path: String, _ args: [String], environment: [String: String]? = nil) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    if let environment { p.environment = environment }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    // Lenient: one process with non-UTF-8 arguments must not blank the whole ps listing.
    return String(decoding: data, as: UTF8.self)
}

func processTable() -> [Proc] {
    run("/bin/ps", ["-axo", "pid=,ppid=,tty=,comm="]).split(separator: "\n").compactMap { line in
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { return nil }
        return Proc(pid: pid, ppid: ppid, tty: String(parts[2]), comm: parts[3].trimmingCharacters(in: .whitespaces))
    }
}

func workingDirectory(of pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return path.isEmpty ? nil : path
}

// MARK: - Detection

struct ClaudeSession: Decodable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let name: String?
    let nameSource: String?
    let status: String?
    let kind: String?
}

// MARK: - Session topic

func isValidSessionId(_ id: String) -> Bool {
    id.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil
}

/// The folder name Claude Code keeps a cwd's transcripts under: every character but A-Z, a-z, 0-9 becomes "-".
func projectSlug(_ cwd: String) -> String {
    String(decoding: cwd.utf16.map { c in
        (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) ? c : 45
    }, as: UTF16.self)
}

func transcriptURL(sessionId: String, cwd: String? = nil) -> URL? {
    guard isValidSessionId(sessionId) else { return nil }
    let projects = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects", isDirectory: true)
    if let cwd {
        // Usually the transcript is under the cwd's own folder; long or unusual paths are found by the scan below.
        let file = projects.appendingPathComponent(projectSlug(cwd), isDirectory: true).appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: file.path) { return file }
    }
    let dirs = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
    for dir in dirs {
        let file = dir.appendingPathComponent("\(sessionId).jsonl")
        if FileManager.default.fileExists(atPath: file.path) { return file }
    }
    return nil
}

/// Finds the last transcript line of the given record type and returns one of its string fields.
func lastRecord(in data: Data, type: String, field: String) -> String? {
    guard let marker = "\"type\":\"\(type)\"".data(using: .utf8) else { return nil }
    let newline = UInt8(ascii: "\n")
    var end = data.endIndex
    while let hit = data.range(of: marker, options: .backwards, in: data.startIndex..<end) {
        let lineStart = data[data.startIndex..<hit.lowerBound].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
        let lineEnd = data[hit.upperBound..<data.endIndex].firstIndex(of: newline) ?? data.endIndex
        // The marker also appears inside quoted message text; only accept a line that really is this record.
        if lineEnd - lineStart < 1_000_000,
           let object = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]) as? [String: Any],
           object["type"] as? String == type,
           let value = object[field] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        end = hit.lowerBound
    }
    return nil
}

/// Finds the first transcript line of the given record type that has a non-empty string field.
func firstRecord(in data: Data, type: String, field: String) -> String? {
    guard let marker = "\"type\":\"\(type)\"".data(using: .utf8) else { return nil }
    let newline = UInt8(ascii: "\n")
    var start = data.startIndex
    while start < data.endIndex, let hit = data.range(of: marker, in: start..<data.endIndex) {
        let lineStart = data[data.startIndex..<hit.lowerBound].lastIndex(of: newline).map { $0 + 1 } ?? data.startIndex
        let lineEnd = data[hit.upperBound..<data.endIndex].firstIndex(of: newline) ?? data.endIndex
        if lineEnd - lineStart < 1_000_000,
           let object = try? JSONSerialization.jsonObject(with: data[lineStart..<lineEnd]) as? [String: Any],
           object["type"] as? String == type,
           let value = object[field] as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        start = lineEnd
    }
    return nil
}

struct TranscriptTitles {
    var custom: String?       // set with /rename
    var generated: String?    // Claude Code's own title
    var firstPrompt: String?
}

/// Transcripts only grow, so a file of the same size and date has the same titles.
private var titleCache: [String: (size: Int, date: Date, titles: TranscriptTitles)] = [:]
private let titleCacheLock = NSLock()

func transcriptTitles(_ url: URL) -> TranscriptTitles? {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let size = values?.fileSize ?? -1
    let date = values?.contentModificationDate ?? .distantPast
    titleCacheLock.lock()
    let cached = titleCache[url.path]
    titleCacheLock.unlock()
    if let cached, cached.size == size, cached.date == date { return cached.titles }

    guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
    var titles = TranscriptTitles()
    titles.custom = lastRecord(in: data, type: "custom-title", field: "customTitle")
    titles.generated = lastRecord(in: data, type: "ai-title", field: "aiTitle")
    if titles.custom == nil && titles.generated == nil,
       let prompt = firstRecord(in: data, type: "last-prompt", field: "lastPrompt") {
        let oneLine = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? prompt
        titles.firstPrompt = oneLine.count > 40 ? String(oneLine.prefix(40)) + "…" : oneLine
    }
    titleCacheLock.lock()
    titleCache[url.path] = (size, date, titles)
    titleCacheLock.unlock()
    return titles
}

/// The session's topic, in the order Claude Code's own session list uses: its /rename,
/// else the generated title, else a name it was given, else the first thing the user typed.
func sessionTopic(sessionId: String, cwd: String? = nil, userName: String? = nil, transcript: URL?? = nil) -> String? {
    let url = transcript ?? transcriptURL(sessionId: sessionId, cwd: cwd)
    let titles = url.flatMap(transcriptTitles)
    return titles?.custom ?? titles?.generated ?? userName ?? titles?.firstPrompt
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
func detectTerminalTabs(includeTopics: Bool = true) -> [Entry] {
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
        // The process must really be Claude: a leftover session file can name a pid that has since been reused.
        if let hit = descendants.first(where: { sessions[$0.pid] != nil && ($0.comm as NSString).lastPathComponent == "claude" }),
           let s = sessions[hit.pid] {
            // A name the user chose themselves wins over the generated topic.
            let userName = s.nameSource != "derived" && !(s.name ?? "").isEmpty ? s.name : nil
            let topic = includeTopics ? (sessionTopic(sessionId: s.sessionId, cwd: s.cwd, userName: userName) ?? "") : userName
            entries.append(Entry(kind: "claude", cwd: s.cwd, tty: login.tty,
                                 sessionId: s.sessionId, name: s.name, status: s.status, topic: topic))
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
    let validId = entry.sessionId.map(isValidSessionId) ?? false
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

// MARK: - Finish one session

enum FinishError: Error {
    case gone
    case automationDenied
    case script(String)
    case notSaved
}

/// Saves one Terminal tab's Claude session under Finished and ends it. Returns the ids of the
/// windows to close once its processes have exited (none when the tab shares its window).
func finishTerminalSession(tty: String, sessionId: String) throws -> (entry: Entry, windowIds: [Int]) {
    guard var entry = detectTerminalTabs().first(where: { $0.tty == tty && $0.sessionId == sessionId }) else {
        throw FinishError.gone
    }
    // Nothing was ever sent, so there is nothing to resume: reopen it as a shell in its folder.
    let size = transcriptURL(sessionId: sessionId, cwd: entry.cwd)
        .flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
    if size == 0 {
        entry.kind = "shell"
        entry.sessionId = nil
    }
    // Ask Terminal first, so a missing Automation permission stops everything before anything ends.
    let ids: [Int]
    do {
        ids = try windowIds(coveredBy: [tty])
    } catch CloseError.automationDenied {
        throw FinishError.automationDenied
    } catch {
        throw FinishError.script("\(error)")
    }
    guard History.addFinished(entry) else { throw FinishError.notSaved }
    hangUp(ttys: [tty])
    return (entry, ids)
}

/// Sends SIGHUP to everything running on the given ttys, the same signal Terminal sends when a window closes.
func hangUp(ttys: [String]) {
    let targets = Set(ttys)
    for p in processTable() where targets.contains(p.tty) && p.pid != getpid() {
        kill(p.pid, SIGHUP)
    }
}
