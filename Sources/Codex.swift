import Foundation

/// Support for OpenAI Codex CLI sessions.
///
/// Codex keeps no per-process session file, so a running `codex` is matched to its session from
/// what can be observed: the session file it holds open, the id it was started with, and which
/// sessions in its folder were created after it started. If nothing points to one session alone
/// (for example before the first message is sent), the tab is still recorded and reopens with
/// Codex's own picker.
enum Codex {
    static let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)

    struct Session: Equatable {
        let id: String
        let cwd: String
        let created: Date
        let modified: Date
    }

    /// One running codex process and what is known about it.
    struct Running {
        let pid: Int32
        let cwd: String
        let started: Date
        /// The id in `codex resume <id>`, if it was started that way.
        let resumeId: String?
        /// The session whose file the process holds open, if any.
        let openId: String?
    }

    /// When the process started, from the kernel.
    static func startTime(of pid: Int32) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec))
    }

    private static let timestampFormats: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [fractional, ISO8601DateFormatter()]
    }()

    /// Reads the session header (first line) of a rollout file.
    static func header(of file: URL) -> (id: String, cwd: String, created: Date?)? {
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
        let stamp = (payload["timestamp"] as? String) ?? (object["timestamp"] as? String)
        let created = stamp.flatMap { text in timestampFormats.lazy.compactMap { $0.date(from: text) }.first }
        return (id, cwd, created)
    }

    /// Terminal sessions written to since `since`, newest first.
    static func sessions(modifiedSince since: Date) -> [Session] {
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return [] }
        var result: [Session] = []
        for case let file as URL in walker where file.pathExtension == "jsonl" {
            guard let values = try? file.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate,
                  modified >= since, let head = header(of: file) else { continue }
            result.append(Session(id: head.id, cwd: head.cwd,
                                  created: head.created ?? values.creationDate ?? modified, modified: modified))
        }
        return result.sorted { $0.modified > $1.modified }
    }

    // MARK: What one process tells us

    static func resumedId(inArguments args: String) -> String? {
        let words = args.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let i = words.firstIndex(of: "resume") else { return nil }
        // A session id is a UUID; a word like a prompt or a flag value must not be mistaken for one.
        return words[(i + 1)...].first { UUID(uuidString: $0) != nil }
    }

    /// A process's command line never changes, so it is read once per process.
    private static var resumeCache: [Int32: (started: Date, id: String?)] = [:]
    private static let lock = NSLock()

    static func resumedId(of pid: Int32, started: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let hit = resumeCache[pid], hit.started == started { return hit.id }
        let id = resumedId(inArguments: run("/bin/ps", ["-ww", "-o", "args=", "-p", String(pid)]))
        if resumeCache.count > 200 { resumeCache.removeAll() }
        resumeCache[pid] = (started, id)
        return id
    }

    /// Paths of the regular files a process holds open.
    static func openFiles(of pid: Int32) -> [String] {
        let stride = MemoryLayout<proc_fdinfo>.stride
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / stride + 16)
        let used = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard used > 0 else { return [] }
        var paths: [String] = []
        for fd in fds.prefix(Int(used) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    /// The session whose rollout file the process has open, if it keeps one open.
    static func openSessionId(of pid: Int32) -> String? {
        let root = home.appendingPathComponent("sessions", isDirectory: true).path + "/"
        for path in openFiles(of: pid) where path.hasPrefix(root) && path.hasSuffix(".jsonl") {
            if let head = header(of: URL(fileURLWithPath: path)) { return head.id }
        }
        return nil
    }

    // MARK: Matching processes to sessions

    /// Sessions for all running codex processes at once: one walk of the sessions folder, and
    /// no two processes ever get the same session.
    static func sessionIds(for procs: [(pid: Int32, cwd: String)]) -> [Int32: String] {
        guard !procs.isEmpty else { return [:] }
        let running: [Running] = procs.map { p in
            let started = startTime(of: p.pid) ?? Date()
            return Running(pid: p.pid, cwd: p.cwd, started: started,
                           resumeId: resumedId(of: p.pid, started: started), openId: openSessionId(of: p.pid))
        }
        let earliest = running.map(\.started).min() ?? Date()
        return match(running, sessions: sessions(modifiedSince: earliest.addingTimeInterval(-slack)))
    }

    /// Clock slack between a process starting and its session file's timestamps.
    static let slack: TimeInterval = 5

    /// Decides which session each process shows. A process keeps a session only when the evidence
    /// points to it alone; when two tabs in one folder cannot be told apart, neither gets one and
    /// they reopen with Codex's own picker rather than the wrong conversation.
    static func match(_ procs: [Running], sessions: [Session]) -> [Int32: String] {
        let procs = procs.sorted { ($0.started, $0.pid) < ($1.started, $1.pid) }
        var result: [Int32: String] = [:]
        var claimed = Set<String>()
        func claim(_ id: String, for pid: Int32) {
            if let old = result[pid] { claimed.remove(old) }
            result[pid] = id
            claimed.insert(id)
        }
        // A session the process created or continued: in its folder, and not from before it started.
        func createdBy(_ p: Running, _ s: Session) -> Bool {
            p.cwd == s.cwd && s.created >= p.started.addingTimeInterval(-slack)
        }

        // 1. The file it holds open is exact.
        for p in procs {
            if let id = p.openId, !claimed.contains(id) { claim(id, for: p.pid) }
        }
        // 2. `codex resume <id>` names its session.
        for p in procs where result[p.pid] == nil {
            if let id = p.resumeId, !claimed.contains(id) { claim(id, for: p.pid) }
        }
        // 3. A session created after exactly one still-unmatched process started is that process's.
        //    Each match can settle the next (the second tab's session, once the first tab has its own).
        var progress = true
        while progress {
            progress = false
            for s in sessions.sorted(by: { $0.created < $1.created }) where !claimed.contains(s.id) {
                let owners = procs.filter { result[$0.pid] == nil && createdBy($0, s) }
                if owners.count == 1 {
                    claim(s.id, for: owners[0].pid)
                    progress = true
                }
            }
        }
        // 4. A newer session only one process could have created (/new inside the tab) replaces
        //    what steps 2 and 3 found for it.
        for s in sessions where !claimed.contains(s.id) {      // newest first
            let owners = procs.filter { $0.openId == nil && createdBy($0, s) }
            guard owners.count == 1, let p = owners.first else { continue }
            let current = result[p.pid].flatMap { id in sessions.first { $0.id == id }?.modified } ?? .distantPast
            if s.modified > current { claim(s.id, for: p.pid) }
        }
        // 5. An older session picked inside the tab: written to since the process started. Only when
        //    one unmatched process and one such session are left in the folder.
        for p in procs where result[p.pid] == nil {
            let alone = procs.filter { result[$0.pid] == nil && $0.cwd == p.cwd }.count == 1
            let written = sessions.filter {
                !claimed.contains($0.id) && $0.cwd == p.cwd && $0.modified >= p.started.addingTimeInterval(-slack)
            }
            if alone, written.count == 1 { claim(written[0].id, for: p.pid) }
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
