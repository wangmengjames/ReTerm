import AppKit
import Foundation

// MARK: - Where Terminal windows are

func isValidTty(_ tty: String) -> Bool {
    tty.range(of: "^ttys[0-9]{1,5}$", options: .regularExpression) != nil
}

private func runAppleScript(_ source: String) throws -> NSAppleEventDescriptor {
    var error: NSDictionary?
    guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
        let code = (error?[NSAppleScript.errorNumber] as? Int) ?? 0
        if code == -1743 { throw CloseError.automationDenied }
        throw CloseError.script((error?[NSAppleScript.errorMessage] as? String) ?? "AppleScript error \(code)")
    }
    return result
}

/// Frame of the window each tab lives in (left, top, right, bottom), keyed by tty ("ttys003").
func windowBounds() throws -> [String: [Int]] {
    let source = """
    with timeout of 5 seconds
        tell application "Terminal"
            set out to ""
            repeat with w in windows
                try
                    set b to bounds of w
                    set ttys to ""
                    repeat with t in tabs of w
                        set ttys to ttys & (tty of t) & " "
                    end repeat
                    set out to out & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & "|" & ttys & linefeed
                end try
            end repeat
            return out
        end tell
    end timeout
    """
    let text = try runAppleScript(source).stringValue ?? ""
    var result: [String: [Int]] = [:]
    for line in text.split(whereSeparator: \.isNewline) {
        let parts = line.split(separator: "|", maxSplits: 1)
        guard parts.count == 2 else { continue }
        let numbers = parts[0].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4 else { continue }
        for device in parts[1].split(separator: " ") {
            result[device.replacingOccurrences(of: "/dev/", with: "")] = numbers
        }
    }
    return result
}

/// Adds each entry's window frame. Entries are left as they are if Terminal cannot be asked.
func withBounds(_ entries: [Entry]) -> [Entry] {
    guard let frames = try? windowBounds() else { return entries }
    return entries.map { entry in
        var copy = entry
        copy.bounds = frames[entry.tty]
        return copy
    }
}

func setWindowBounds(tty: String, bounds: [Int]) {
    guard isValidTty(tty), bounds.count == 4 else { return }
    let source = """
    with timeout of 5 seconds
        tell application "Terminal"
            repeat with w in windows
                try
                    if (count of tabs of w) is 1 and (tty of tab 1 of w) is "/dev/\(tty)" then
                        set bounds of w to {\(bounds.map(String.init).joined(separator: ", "))}
                    end if
                end try
            end repeat
        end tell
    end timeout
    """
    _ = try? runAppleScript(source)
}

/// A frame from Terminal (left, top, right, bottom; origin at the top-left of the main display) as a screen rectangle.
private func screenRect(_ bounds: [Int]) -> CGRect? {
    guard bounds.count == 4, let mainHeight = NSScreen.screens.first?.frame.height else { return nil }
    return CGRect(x: CGFloat(bounds[0]), y: mainHeight - CGFloat(bounds[3]),
                  width: CGFloat(bounds[2] - bounds[0]), height: CGFloat(bounds[3] - bounds[1]))
}

/// True if enough of this frame is on a screen, so a window saved on a monitor that is no longer
/// attached is not sent off-screen.
func isOnScreen(_ bounds: [Int]) -> Bool {
    guard let rect = screenRect(bounds), rect.width >= 100, rect.height >= 60 else { return false }
    return NSScreen.screens.contains { screen in
        let overlap = screen.frame.intersection(rect)
        return overlap.width >= 100 && overlap.height >= 60
    }
}

/// True if the whole frame lies on one screen.
func isFullyOnScreen(_ bounds: [Int]) -> Bool {
    guard let rect = screenRect(bounds) else { return false }
    return NSScreen.screens.contains { $0.frame.contains(rect) }
}

/// Moves a reopened window to its old frame once the new tab has reported which tty it got.
/// A tab that joined an existing window (Terminal set to open in tabs) is left where it is.
enum Placement {
    /// Frames promised to windows that are still opening. Main thread only.
    private static var pending: [UUID: (frame: [Int], at: Date)] = [:]

    /// The saved frame, or the nearest free one 24 points down and right when a window already
    /// sits exactly there (tabs saved from one window share a frame). nil when no free spot is
    /// left on the screen: Terminal then places the window itself.
    static func freeFrame(_ saved: [Int], occupied: Set<[Int]>, fits: ([Int]) -> Bool = isFullyOnScreen) -> [Int]? {
        var frame = saved
        var steps = 0
        while occupied.contains(frame) {
            frame = frame.map { $0 + 24 }
            steps += 1
            // The saved frame itself is used as it is; a shifted one must stay wholly on a screen.
            if steps > 40 || !fits(frame) { return nil }
        }
        return frame
    }

    static func place(reportFile: URL, saved: [Int]) {
        let now = Date()
        pending = pending.filter { now.timeIntervalSince($0.value.at) < 20 }
        // Where windows really are now, plus where windows still opening are headed.
        let existing = (try? windowBounds()).map { Set($0.values) } ?? []
        guard let bounds = freeFrame(saved, occupied: existing.union(pending.values.map(\.frame))) else { return }
        let token = UUID()
        pending[token] = (bounds, now)

        var tries = 0
        let timer = Timer(timeInterval: 0.3, repeats: true) { timer in
            tries += 1
            if let text = try? String(contentsOf: reportFile, encoding: .utf8) {
                let tty = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/dev/", with: "")
                if isValidTty(tty) {
                    timer.invalidate()
                    try? FileManager.default.removeItem(at: reportFile)
                    setWindowBounds(tty: tty, bounds: bounds)
                    // From here the window's real position speaks for itself.
                    pending[token] = nil
                    return
                }
            }
            if tries >= 40 {
                timer.invalidate()
                pending[token] = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
