import AppKit
import Foundation

/// Remembers Claude Code sessions that end without ReTerm being told: a Terminal window closed by
/// hand, Terminal quit, a restart. Each one is saved under "Closed today", ready to reopen.
///
/// It watches only the small files in ~/.claude/sessions; the process list is read just when a new
/// session appears, to learn which Terminal tab it is in.
final class Tracker {
    static let shared = Tracker()
    static let key = "recordClosedSessions"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// One Claude Code session running in a Terminal tab, as last seen.
    struct Tracked: Codable, Equatable {
        var pid: Int32
        /// With the pid, identifies the process: pids are reused.
        var started: Date
        var sessionId: String
        var cwd: String
        var tty: String
        /// A name the user gave the session.
        var name: String?
        var bounds: [Int]?
    }

    /// What was running when ReTerm last looked, kept on disk so sessions that end while ReTerm
    /// is not running (restart, logout, crash) are still noticed.
    private struct Seen: Codable {
        var date: Date
        var sessions: [Tracked]
    }

    /// Called on the main thread after a session has been saved.
    var onRecorded: () -> Void = {}

    // All state below is touched on the main thread only.
    private var known: [Int32: Tracked] = [:]
    private var notInTerminal: Set<Int32> = []
    private var suppressed: [String: Date] = [:]
    private var written: [Tracked] = []
    private var tick = 0
    private var looking = false
    private var timer: Timer?
    private let queue = DispatchQueue(label: "ReTerm.tracker", qos: .utility)

    // MARK: Starting and stopping

    func start() {
        guard Tracker.enabled, timer == nil else { return }
        recoverFromLastRun()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.look() }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        look()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        known = [:]
        notInTerminal = []
        written = []
        // Nothing is being watched any more, so nothing may be "recovered" from this later.
        try? FileManager.default.removeItem(at: Paths.seen)
    }

    /// These sessions are about to be closed on purpose and are already saved (Done, Save & Close).
    func suppress(sessionIds: [String]) {
        let until = Date().addingTimeInterval(90)
        for id in sessionIds { suppressed[id] = until }
    }

    // MARK: Looking

    /// The same process as when it was first seen.
    static func isAlive(_ t: Tracked) -> Bool {
        Codex.startTime(of: t.pid) == t.started
    }

    private func look() {
        guard !looking else { return }
        looking = true
        tick += 1
        // Sessions outside Terminal are looked at again now and then, in case one was missed mid-start.
        if tick % 20 == 0 { notInTerminal = [] }
        let known = self.known
        let skip = notInTerminal
        let periodic = tick % 5 == 0
        queue.async {
            let records = liveRecords()
            let newcomers = records.filter { known[$0.pid] == nil && !skip.contains($0.pid) }
            var tabs: [Entry] = []
            var starts: [Int32: Date] = [:]
            if !newcomers.isEmpty {
                tabs = detectTerminalTabs(includeTopics: false, codexSessions: false)
                for r in newcomers { starts[r.pid] = Codex.startTime(of: r.pid) }
            }
            let gone = known.values.filter { !Tracker.isAlive($0) }
            // Window frames are read only if macOS already lets ReTerm talk to Terminal: never a prompt from here.
            let wantFrames = (!newcomers.isEmpty || periodic) && (!known.isEmpty || !newcomers.isEmpty)
                && automationAllowedSilently()
            DispatchQueue.main.async {
                self.apply(records: records, newcomers: newcomers, tabs: tabs, starts: starts, gone: gone, readFrames: wantFrames)
                self.looking = false
            }
        }
    }

    private func apply(records: [SessionRecord], newcomers: [SessionRecord], tabs: [Entry], starts: [Int32: Date],
                       gone: [Tracked], readFrames: Bool) {
        guard timer != nil else { return }      // stopped while this look was under way
        // A session can change under the same process (/clear, /resume): follow it.
        for r in records {
            guard var t = known[r.pid], !gone.contains(where: { $0.pid == r.pid }) else { continue }
            t.sessionId = r.sessionId
            t.cwd = r.cwd
            t.name = r.userName
            known[r.pid] = t
        }
        for r in newcomers {
            if let tab = tabs.first(where: { $0.kind == "claude" && $0.sessionId == r.sessionId }), let started = starts[r.pid] {
                known[r.pid] = Tracked(pid: r.pid, started: started, sessionId: r.sessionId, cwd: r.cwd,
                                       tty: tab.tty, name: r.userName, bounds: nil)
            } else {
                notInTerminal.insert(r.pid)
            }
        }
        if readFrames, let frames = try? windowBounds() {
            for (pid, t) in known {
                if let frame = frames[t.tty] { known[pid]?.bounds = frame }
            }
        }
        let now = Date()
        suppressed = suppressed.filter { $0.value > now }
        var recorded = false
        for t in gone {
            // Its latest state, including a session id that changed since the look began.
            guard let last = known.removeValue(forKey: t.pid) else { continue }
            if record(last, at: now) { recorded = true }
        }
        notInTerminal = notInTerminal.filter { pid in records.contains { $0.pid == pid } }
        persist()
        if recorded { onRecorded() }
    }

    /// Saves an ended session. False if there was nothing worth saving.
    @discardableResult
    private func record(_ t: Tracked, at date: Date) -> Bool {
        if suppressed[t.sessionId] != nil { return false }
        // Nothing was ever sent: there is no conversation to come back to.
        let transcript = transcriptURL(sessionId: t.sessionId, cwd: t.cwd)
        let size = transcript.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        guard size > 0 else { return false }
        let topic = sessionTopic(sessionId: t.sessionId, cwd: t.cwd, userName: t.name, transcript: transcript) ?? ""
        let entry = Entry(kind: "claude", cwd: t.cwd, tty: t.tty, sessionId: t.sessionId, name: t.name,
                          topic: topic, bounds: t.bounds)
        return History.addClosedAutomatically(entry, at: date)
    }

    // MARK: Surviving restarts

    private func persist() {
        let sessions = known.values.sorted { $0.pid < $1.pid }
        guard sessions != written else { return }
        written = sessions
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(Seen(date: Date(), sessions: sessions)) {
            try? data.write(to: Paths.seen, options: .atomic)
        }
    }

    /// Whatever was running when ReTerm last looked and is gone now ended while ReTerm was not
    /// running. Save it, dated to when it was last seen.
    private func recoverFromLastRun() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: Paths.seen), let seen = try? decoder.decode(Seen.self, from: data) else { return }
        var recorded = false
        for t in seen.sessions {
            if Tracker.isAlive(t) {
                known[t.pid] = t
            } else if record(t, at: seen.date) {
                recorded = true
            }
        }
        written = seen.sessions
        persist()
        if recorded { onRecorded() }
    }
}

/// True if macOS already allows ReTerm to control Terminal. Never shows the permission prompt.
func automationAllowedSilently() -> Bool {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").isEmpty else { return false }
    let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.Terminal")
    guard let desc = target.aeDesc else { return false }
    return AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) == noErr
}
