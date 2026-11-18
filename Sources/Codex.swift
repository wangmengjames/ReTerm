import Foundation

/// Support for OpenAI Codex CLI sessions.
///
/// Codex keeps no per-process session file, so a running `codex` is matched to its session
/// by folder and time: the newest terminal session recorded for the process's folder that
/// was written to after the process started. If nothing matches (for example before the
/// first message is sent), the tab is still recorded and reopens with Codex's own picker.
enum Codex {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)

    struct Session {
        let id: String
        let cwd: String
        let modified: Date
    }

    /// When the process started, from the kernel.
    static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    /// Reads the session header (first line) of a rollout file.
    static func header(of file: URL) -> (id: String, cwd: String)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        // The first line carries the full system prompt, so it can be long.
        while data.count < 2_000_000, let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: UInt8(ascii: "\n")) {
                data.append(chunk[chunk.startIndex..<newline])
                break
            }
            data.append(chunk)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["type"] as? String == "session_meta",
              let payload = object["payload"] as? [String: Any],
              payload["originator"] as? String == "codex-tui",
              payload["source"] is String,                       // sub-agent threads have an object here
              let id = payload["id"] as? String, isValidSessionId(id),
              let cwd = payload["cwd"] as? String else { return nil }
        return (id, cwd)
    }

    /// Terminal sessions written to since `since`, newest first.
    static func sessions(modifiedSince since: Date) -> [Session] {
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var result: [Session] = []
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified >= since, let head = header(of: file) else { continue }
            result.append(Session(id: head.id, cwd: head.cwd, modified: modified))
        }
        return result.sorted { $0.modified > $1.modified }
    }

    private static var cache: [Int32: (id: String?, checked: Date)] = [:]
    private static let lock = NSLock()

    /// The id in `codex resume <id>`, if the process was started that way.
    static func resumedId(of pid: Int32) -> String? {
        resumedId(inArguments: run("/bin/ps", ["-ww", "-o", "args=", "-p", String(pid)]))
    }

    static func resumedId(inArguments args: String) -> String? {
        let words = args.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let i = words.firstIndex(of: "resume") else { return nil }
        // A session id is a UUID; a word like a prompt or a flag value must not be mistaken for one.
        return words[(i + 1)...].first { UUID(uuidString: $0) != nil }
    }

    /// The session a running codex process is most likely showing, or nil if it cannot be told:
    /// the newest session written in its folder since it started, else the one it was started to resume.
    static func sessionId(pid: Int32, cwd: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        // "Not found" is rechecked soon: a new session is only written once its first message is sent.
        if let hit = cache[pid], Date().timeIntervalSince(hit.checked) < (hit.id == nil ? 2 : 30) { return hit.id }
        let started = startTime(of: pid) ?? Date()
        let id = sessions(modifiedSince: started.addingTimeInterval(-5)).first { $0.cwd == cwd }?.id
            ?? resumedId(of: pid)
        cache[pid] = (id, Date())
        if cache.count > 200 { cache = cache.filter { Date().timeIntervalSince($0.value.checked) < 300 } }
        return id
    }

    /// Sessions for several codex processes at once. An id that more than one process would claim
    /// (two tabs in one folder) is kept only by a process started to resume exactly it; the others
    /// get none and reopen with Codex's own picker instead of the wrong conversation.
    static func sessionIds(for procs: [(pid: Int32, cwd: String)]) -> [Int32: String] {
        var ids: [Int32: String] = [:]
        for p in procs { ids[p.pid] = sessionId(pid: p.pid, cwd: p.cwd) }
        return settle(ids) { resumedId(of: $0) }
    }

    static func settle(_ ids: [Int32: String], resumed: (Int32) -> String?) -> [Int32: String] {
        var result = ids
        let shared = Dictionary(grouping: ids.keys, by: { ids[$0]! }).filter { $0.value.count > 1 }
        for (id, pids) in shared {
            let owners = pids.filter { resumed($0) == id }
            for pid in pids where !(owners.count == 1 && owners[0] == pid) {
                // A process started to resume a different session, which no other tab has, keeps that one.
                if let own = resumed(pid), own != id, !ids.values.contains(own) {
                    result[pid] = own
                } else {
                    result[pid] = nil
                }
            }
        }
        return result
    }

    /// The name Codex gave the session, from its index.
    static func topic(sessionId: String) -> String? {
        let index = home.appendingPathComponent("session_index.jsonl")
        guard let text = try? String(contentsOf: index, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: \.isNewline).reversed() where line.contains(sessionId) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["id"] as? String == sessionId,
                  let name = (object["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            return name
        }
        return nil
    }
}
