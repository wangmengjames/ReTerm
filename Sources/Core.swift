import AppKit
import Foundation

// MARK: - Model

struct Entry: Codable {
    var id = UUID()
    var kind: String            // "claude", "codex" or "shell"
    var cwd: String
    var tty: String             // e.g. "ttys005"
    var sessionId: String?
    var name: String?
    var status: String?
    var reopened = false
    /// What the session is about (Claude Code's own window title). nil = not looked up yet, "" = none found.
    var topic: String?
    /// Frame of the window it was in, as Terminal reports it: left, top, right, bottom.
    var bounds: [Int]? = nil

    var isSession: Bool { kind != "shell" }
    /// Identifies what would be reopened, wherever it was recorded.
    var pinKey: String { sessionId.map { "\(kind):\($0)" } ?? "\(kind):\(cwd)" }

    var title: String {
        let folder = (cwd as NSString).lastPathComponent
        if let topic, !topic.isEmpty { return topic }
        if let name, !name.isEmpty { return name }
        return folder.isEmpty ? cwd : folder
    }

    /// SF Symbol shown next to the entry.
    var symbol: String {
        switch kind {
        case "claude": return "sparkles"
        case "codex": return "chevron.left.forwardslash.chevron.right"
        default: return "terminal"
        }
    }

    var shortPath: String { (cwd as NSString).abbreviatingWithTildeInPath }
}

/// A title as shown: itself, or its folder's name while Hide Session Titles is on.
func displayTitle(_ title: String, cwd: String, hidden: Bool) -> String {
    guard hidden else { return title }
    let folder = (cwd as NSString).lastPathComponent
    return folder.isEmpty ? cwd : folder
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
        // RETERM_HOME points ReTerm at another data folder (used for testing).
        let custom = ProcessInfo.processInfo.environment["RETERM_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = custom ?? base.appendingPathComponent("ReTerm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    static let history = support.appendingPathComponent("history.json")
    static let pins = support.appendingPathComponent("pins.json")
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

    static func load() -> [Snapshot] { loadForChange() ?? [] }

    /// The history to change and save back: nil when the file exists but cannot be read
    /// (a permission or disk error), so a save never replaces history it could not see.
    static func loadForChange() -> [Snapshot]? {
        guard FileManager.default.fileExists(atPath: Paths.history.path) else { return [] }
        guard let data = try? Data(contentsOf: Paths.history) else { return nil }
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
        guard var all = loadForChange() else { return false }
        all.insert(snapshot, at: 0)
        return save(all)
    }

    /// Fills in missing session topics (for snapshots saved before topics existed) and stores them.
    static func loadFillingTopics() -> [Snapshot] {
        guard var all = loadForChange() else { return [] }
        var changed = false
        for s in all.indices {
            for e in all[s].entries.indices where all[s].entries[e].isSession && all[s].entries[e].topic == nil {
                all[s].entries[e].topic = storedTopic(for: all[s].entries[e]) ?? ""
                changed = true
            }
        }
        if changed { save(all) }
        return all
    }

    /// Adds a session marked finished to today's Finished group (moved to the top), or starts one.
    @discardableResult
    static func addFinished(_ entry: Entry, now: Date = Date()) -> Bool {
        guard var all = loadForChange() else { return false }
        if let i = all.firstIndex(where: { $0.finished == true && Calendar.current.isDate($0.date, inSameDayAs: now) }) {
            var today = all.remove(at: i)
            today.entries.insert(entry, at: 0)
            today.date = now
            all.insert(today, at: 0)
        } else {
            all.insert(Snapshot(date: now, closed: true, entries: [entry], finished: true), at: 0)
        }
        return save(all)
    }

    static func markReopened(snapshot: UUID, entry: UUID) {
        guard var all = loadForChange() else { return }
        guard let s = all.firstIndex(where: { $0.id == snapshot }),
              let e = all[s].entries.firstIndex(where: { $0.id == entry }) else { return }
        all[s].entries[e].reopened = true
        save(all)
    }

    static func markReopened(entry: UUID) {
        guard var all = loadForChange() else { return }
        for s in all.indices {
            if let e = all[s].entries.firstIndex(where: { $0.id == entry }) {
                all[s].entries[e].reopened = true
                save(all)
                return
            }
        }
    }

    /// Removes one entry, and its group once that is empty.
    @discardableResult
    static func delete(entry: UUID) -> Bool {
        guard var all = loadForChange() else { return false }
        for i in all.indices { all[i].entries.removeAll { $0.id == entry } }
        all.removeAll { $0.entries.isEmpty }
        return save(all)
    }

    /// The most recently saved entry that has not been reopened yet.
    static func lastClosed() -> Entry? {
        for snapshot in load() where snapshot.closed {
            if let hit = snapshot.entries.first(where: { !$0.reopened }) { return hit }
        }
        return nil
    }
}

// MARK: - Pins

/// Entries the user wants to keep at hand. Stored apart from history so they never age out.
enum Pins {
    static func load() -> [Entry] { loadForChange() ?? [] }

    /// nil when the file exists but cannot be read, so a save never replaces pins it could not see.
    private static func loadForChange() -> [Entry]? {
        guard FileManager.default.fileExists(atPath: Paths.pins.path) else { return [] }
        guard let data = try? Data(contentsOf: Paths.pins) else { return nil }
        do {
            return try JSONDecoder().decode([Entry].self, from: data)
        } catch {
            let aside = Paths.support.appendingPathComponent("pins.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Paths.pins, to: aside)
            return []
        }
    }

    @discardableResult
    private static func save(_ entries: [Entry]) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return false }
        return (try? data.write(to: Paths.pins, options: .atomic)) != nil
    }

    static func contains(_ entry: Entry) -> Bool {
        load().contains { $0.pinKey == entry.pinKey }
    }

    /// Pins the entry, or unpins it if it is already pinned.
    @discardableResult
    static func toggle(_ entry: Entry) -> Bool {
        guard var all = loadForChange() else { return false }
        if all.contains(where: { $0.pinKey == entry.pinKey }) {
            all.removeAll { $0.pinKey == entry.pinKey }
        } else {
            var copy = entry
            copy.id = UUID()
            copy.reopened = false
            copy.status = nil
            all.append(copy)
        }
        return save(all)
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

/// The topic to store for a saved entry of either kind.
func storedTopic(for entry: Entry) -> String? {
    guard let id = entry.sessionId else { return nil }
    return entry.kind == "codex" ? Codex.topic(sessionId: id) : sessionTopic(sessionId: id, cwd: entry.cwd)
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
/// `codexSessions: false` skips working out which session each Codex tab shows (enough for a count).
func detectTerminalTabs(includeTopics: Bool = true, codexSessions: Bool = true) -> [Entry] {
    let procs = processTable()
    let terminalPids = Set(procs.filter { $0.comm.hasSuffix("/Terminal.app/Contents/MacOS/Terminal") }.map(\.pid))
    let logins = procs.filter { terminalPids.contains($0.ppid) && $0.tty != "??" }
    let sessions = liveClaudeSessions()
    var children: [Int32: [Proc]] = [:]
    for p in procs { children[p.ppid, default: []].append(p) }

    var entries: [Entry] = []
    var codexTabs: [(index: Int, pid: Int32)] = []
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
        } else if let codex = descendants.first(where: { ($0.comm as NSString).lastPathComponent == "codex" }) {
            let cwd = workingDirectory(of: codex.pid) ?? NSHomeDirectory()
            codexTabs.append((entries.count, codex.pid))
            entries.append(Entry(kind: "codex", cwd: cwd, tty: login.tty))
        } else if let outer = descendants.first {
            // The innermost process is where the user actually is (e.g. a shell started by a script).
            let inner = descendants.last ?? outer
            let cwd = workingDirectory(of: inner.pid) ?? workingDirectory(of: outer.pid) ?? NSHomeDirectory()
            entries.append(Entry(kind: "shell", cwd: cwd, tty: login.tty))
        }
    }
    // All Codex tabs are matched to their sessions together, so two tabs never claim the same one.
    guard codexSessions else { return entries }
    let codexIds = Codex.sessionIds(for: codexTabs.map { (pid: $0.pid, cwd: entries[$0.index].cwd) })
    for tab in codexTabs {
        let id = codexIds[tab.pid]
        entries[tab.index].sessionId = id
        entries[tab.index].topic = includeTopics ? (id.flatMap { Codex.topic(sessionId: $0) } ?? "") : nil
    }
    return entries
}

// MARK: - Reopen

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func launchScript(for entry: Entry) -> String {
    // The new tab reports its tty so ReTerm can put the window back where it was.
    var lines = ["#!/bin/zsh", "tty > \(shellQuote(ttyReportFile(for: entry).path)) 2>/dev/null", "clear"]
    lines.append("if ! cd -- \(shellQuote(entry.cwd)); then")
    lines.append("  echo \"ReTerm: folder no longer exists: \"\(shellQuote(entry.cwd))")
    lines.append("  exec \"${SHELL:-/bin/zsh}\" -l")
    lines.append("fi")
    let validId = entry.sessionId.map(isValidSessionId) ?? false
    if entry.kind == "claude", let id = entry.sessionId, validId {
        // Interactive shell so the user's own aliases and PATH apply to `claude`.
        lines.append("exec \"${SHELL:-/bin/zsh}\" -lic 'claude --resume \(id); exec \"${SHELL:-/bin/zsh}\" -l'")
    } else if entry.kind == "codex" {
        // Without a known session, Codex's own picker lists the sessions to choose from.
        let target = (entry.sessionId.flatMap { isValidSessionId($0) ? " " + $0 : nil }) ?? ""
        lines.append("exec \"${SHELL:-/bin/zsh}\" -lic 'codex resume\(target); exec \"${SHELL:-/bin/zsh}\" -l'")
    } else {
        lines.append("exec \"${SHELL:-/bin/zsh}\" -l")
    }
    return lines.joined(separator: "\n") + "\n"
}

func ttyReportFile(for entry: Entry) -> URL {
    Paths.launch.appendingPathComponent("\(entry.id.uuidString).tty")
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
    try? FileManager.default.removeItem(at: ttyReportFile(for: entry))
    NSWorkspace.shared.open([file], withApplicationAt: terminal, configuration: config)
    if let saved = entry.bounds, isOnScreen(saved) {
        Placement.place(reportFile: ttyReportFile(for: entry), saved: saved)
    }
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
    with timeout of 10 seconds
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
    end timeout
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
    with timeout of 10 seconds
    tell application "Terminal"
        repeat with wid in {\(ids.map(String.init).joined(separator: ", "))}
            try
                close (every window whose id is wid) saving no
            end try
        end repeat
    end tell
    end timeout
    """
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
}

// MARK: - Finish one session

enum FinishError: Error {
    case gone
    /// Not idle (working, waiting on you, or in a shell command), with the status Claude Code reported.
    case notFinished(status: String)
    case automationDenied
    case script(String)
    case notSaved
}

struct FinishResult {
    let entry: Entry
    /// Windows that held only this tab, to close once its processes have exited.
    let windowIds: [Int]
    /// Set instead when the tab shares its window: only Claude was ended, and the tab's shell is told to exit.
    let sharedTabTTY: String?
}

/// Saves one Terminal tab's Claude session under Finished and ends it. One detection pass decides
/// everything (which tab, whether it is idle), and nothing ends before every check has passed.
/// Unless `allowUnfinished`, a session that is not idle throws `.notFinished`.
func finishTerminalSession(sessionId: String, allowUnfinished: Bool) throws -> FinishResult {
    // By session id: the tab's login tty can differ from Claude's own (claude run under `script`).
    guard var entry = detectTerminalTabs().first(where: { $0.kind == "claude" && $0.sessionId == sessionId }) else {
        throw FinishError.gone
    }
    let status = entry.status ?? "unknown"
    if status != "idle" && !allowUnfinished { throw FinishError.notFinished(status: status) }
    let tty = entry.tty
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
    let claudePid = liveClaudeSessions().first(where: { $0.value.sessionId == sessionId })?.key
    entry.bounds = (try? windowBounds())?[tty]
    guard History.addFinished(entry) else { throw FinishError.notSaved }
    if ids.isEmpty, let claudePid {
        // The tab shares its window with other tabs. Closing the window would close them too, so end
        // only Claude; `completeFinish` then has the shell exit cleanly, which closes just this tab.
        hangUp(processTreeOf: claudePid)
        return FinishResult(entry: entry, windowIds: [], sharedTabTTY: tty)
    }
    hangUp(ttys: [tty])
    return FinishResult(entry: entry, windowIds: ids, sharedTabTTY: nil)
}

/// The second half of finishing, once the processes have had a moment to exit.
func completeFinish(_ result: FinishResult) {
    if let tty = result.sharedTabTTY {
        exitShell(inTab: tty)
    } else {
        closeWindows(ids: result.windowIds)
    }
}

/// Types `exit` into the tab on this tty, only if nothing but its shell runs there any more,
/// so the shell ends cleanly and Terminal closes the tab (its default for a clean exit).
func exitShell(inTab tty: String) {
    guard tty.range(of: "^ttys[0-9]{1,5}$", options: .regularExpression) != nil else { return }
    let source = """
    with timeout of 10 seconds
    tell application "Terminal"
        repeat with w in windows
            repeat with t in tabs of w
                if (tty of t) is "/dev/\(tty)" then
                    if busy of t is false then do script "exit" in t
                    return
                end if
            end repeat
        end repeat
    end tell
    end timeout
    """
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
}

/// Sends SIGHUP to a process and everything it started.
func hangUp(processTreeOf root: Int32) {
    let procs = processTable()
    var children: [Int32: [Int32]] = [:]
    for p in procs { children[p.ppid, default: []].append(p.pid) }
    var tree: [Int32] = []
    var queue = [root]
    while let pid = queue.popLast() {
        tree.append(pid)
        queue.append(contentsOf: children[pid] ?? [])
    }
    for pid in tree.reversed() where pid != getpid() && pid > 1 {
        kill(pid, SIGHUP)
    }
}

/// Sends SIGHUP to everything running on the given ttys, the same signal Terminal sends when a window closes.
func hangUp(ttys: [String]) {
    let targets = Set(ttys)
    for p in processTable() where targets.contains(p.tty) && p.pid != getpid() {
        kill(p.pid, SIGHUP)
    }
}
