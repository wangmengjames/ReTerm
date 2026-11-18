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

/// Terminal reports frames from the top-left of the main display. True if enough of this one is on a screen,
/// so a window saved on a monitor that is no longer attached is not sent off-screen.
func isOnScreen(_ bounds: [Int]) -> Bool {
    guard bounds.count == 4, bounds[2] - bounds[0] >= 100, bounds[3] - bounds[1] >= 60,
          let mainHeight = NSScreen.screens.first?.frame.height else { return false }
    let rect = CGRect(x: CGFloat(bounds[0]), y: mainHeight - CGFloat(bounds[3]),
                      width: CGFloat(bounds[2] - bounds[0]), height: CGFloat(bounds[3] - bounds[1]))
    return NSScreen.screens.contains { screen in
        let overlap = screen.frame.intersection(rect)
        return overlap.width >= 100 && overlap.height >= 60
    }
}

/// Moves a reopened window to its old frame once the new tab has reported which tty it got.
/// A tab that joined an existing window (Terminal set to open in tabs) is left where it is.
enum Placement {
    private static var recent: [(frame: [Int], at: Date)] = []

    /// Tabs saved from one window share a frame; shift each repeat so reopened windows do not coincide.
    /// Main thread only.
    static func stagger(_ bounds: [Int], now: Date = Date()) -> [Int] {
        recent.removeAll { now.timeIntervalSince($0.at) > 15 }
        var frame = bounds
        while recent.contains(where: { $0.frame == frame }) { frame = frame.map { $0 + 24 } }
        recent.append((frame, now))
        return frame
    }

    static func place(reportFile: URL, bounds: [Int]) {
        var tries = 0
        let timer = Timer(timeInterval: 0.3, repeats: true) { timer in
            tries += 1
            if let text = try? String(contentsOf: reportFile, encoding: .utf8) {
                let tty = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/dev/", with: "")
                if isValidTty(tty) {
                    timer.invalidate()
                    try? FileManager.default.removeItem(at: reportFile)
                    setWindowBounds(tty: tty, bounds: bounds)
                    return
                }
            }
            if tries >= 40 { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
