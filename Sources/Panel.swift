import AppKit
import ServiceManagement
import SwiftUI

// MARK: - Model

/// What a click in the panel asks for; AppDelegate carries it out.
enum PanelAction {
    case jump(LiveSession)
    case finish(LiveSession)
    case reopen(snapshot: UUID, entry: UUID)
    case reopenAll(snapshot: UUID)
    case reopenPin(entry: UUID)
    case reopenLast
    case manage
    case saveAndClose
    case saveOnly
    case installUpdate
    case checkForUpdates
    case toggleLaunchAtLogin
    case toggleHideTitles
    case toggleAutoRecord
    case setLanguage(AppLanguage)
    case clearHistory
    case quit
}

final class PanelModel: ObservableObject {
    static let hideTitlesKey = "hideSessionTitles"

    @Published var live: [LiveSession] = []
    @Published var history: [Snapshot] = []
    @Published var pins: [Entry] = []
    @Published var openTabs = 0
    @Published var update: Updater.Release?
    @Published var hideTitles = UserDefaults.standard.bool(forKey: PanelModel.hideTitlesKey)
    @Published var autoRecord = Tracker.enabled
    @Published var launchAtLogin = false
    @Published var language = Lang.setting
    @Published var showEarlier = false
    @Published var loaded = false
    @Published var now = Date()
    /// Draws without a scroll view, for --render-panel.
    var isSnapshot = false

    var handle: (PanelAction) -> Void = { _ in }

    private var scanning = false
    private var rescan = false
    private let queue = DispatchQueue(label: "ReTerm.scan", qos: .userInitiated)

    /// Reloads the history now and rescans the sessions in the background (ps and transcripts take ~100 ms).
    func reload() {
        history = History.loadFillingTopics()
        pins = Pins.load()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        now = Date()
        guard !scanning else {
            rescan = true
            return
        }
        scanning = true
        let includeTitles = !hideTitles
        queue.async { [weak self] in
            let live = scanLiveSessions(includeTitles: includeTitles)
            let tabs = detectTerminalTabs(includeTopics: false, codexSessions: false).count
            DispatchQueue.main.async {
                guard let self else { return }
                self.live = live
                self.openTabs = tabs
                self.loaded = true
                self.scanning = false
                if self.rescan {
                    self.rescan = false
                    self.reload()
                }
            }
        }
    }

    /// Shown open: everything from today (finished, closed by hand, saved), or failing that the newest group.
    var recent: [Snapshot] {
        let today = history.filter { Calendar.current.isDate($0.date, inSameDayAs: now) }
        return today.isEmpty ? Array(history.prefix(1)) : today
    }

    /// Folded away under "Earlier".
    var earlier: [Snapshot] {
        let shown = Set(recent.map(\.id))
        return history.filter { !shown.contains($0.id) }
    }

    /// A title, or its folder's name while titles are hidden.
    func shown(_ title: String, cwd: String) -> String {
        displayTitle(title, cwd: cwd, hidden: hideTitles)
    }

    /// Only a Terminal session can be closed and later resumed with `claude --resume`.
    func isFinishable(_ session: LiveSession) -> Bool {
        guard session.hostKind == .terminal, case .terminal(let app, _) = session.jump else { return false }
        return app == "Terminal"
    }

    func heading(_ snapshot: Snapshot) -> String {
        let n = snapshot.entries.count
        if snapshot.finished == true || snapshot.auto == true {
            let finished = snapshot.finished == true
            if Calendar.current.isDateInToday(snapshot.date) {
                return finished ? L("Finished today (\(n))", "今天完成（\(n)）") : L("Closed today (\(n))", "今天关闭（\(n)）")
            }
            let f = DateFormatter()
            f.locale = Lang.locale
            f.dateStyle = .medium
            f.timeStyle = .none
            let day = f.string(from: snapshot.date)
            return finished ? L("Finished \(day) (\(n))", "\(day) 完成（\(n)）") : L("Closed \(day) (\(n))", "\(day) 关闭（\(n)）")
        }
        let relative = RelativeDateTimeFormatter()
        relative.locale = Lang.locale
        let when = relative.localizedString(for: snapshot.date, relativeTo: now)
        if snapshot.closed { return L("Closed \(when) (\(n))", "\(when)关闭（\(n)）") }
        return L("Saved \(when) (\(n))", "\(when)保存（\(n)）")
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.isSnapshot {
                content
            } else {
                FittingScroll(maxHeight: 480) { content }
            }
            Divider()
            footer
        }
        .frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.uturn.backward.square")
                .foregroundColor(.secondary)
            Text("ReTerm").font(.headline)
            Spacer()
            if let update = model.update {
                Button(L("Update to \(update.version)", "更新到 \(update.version)")) { model.handle(.installUpdate) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            if model.isSnapshot {
                // ImageRenderer cannot draw AppKit-backed controls such as Menu.
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                Image(systemName: "gearshape").foregroundColor(.secondary)
            } else {
                Button { model.handle(.manage) } label: { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.borderless)
                    .help(L("Search and manage everything ReTerm remembers", "搜索和管理 ReTerm 记住的所有内容"))
                settingsMenu
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var settingsMenu: some View {
        Menu {
            Button(L("Save Snapshot Only", "只保存快照（不关闭）")) { model.handle(.saveOnly) }
                .disabled(model.openTabs == 0)
            Button(L("Reopen Last Closed  \(HotKey.display)", "重新打开上一个关闭的  \(HotKey.display)")) { model.handle(.reopenLast) }
            Button(L("Search & Manage…", "搜索与管理…")) { model.handle(.manage) }
            Divider()
            Toggle(L("Remember Sessions I Close Myself", "自动记住我自己关掉的会话"),
                   isOn: Binding(get: { model.autoRecord }, set: { _ in model.handle(.toggleAutoRecord) }))
            Toggle(L("Hide Session Titles", "隐藏会话标题"),
                   isOn: Binding(get: { model.hideTitles }, set: { _ in model.handle(.toggleHideTitles) }))
            Toggle(L("Launch at Login", "登录时启动"),
                   isOn: Binding(get: { model.launchAtLogin }, set: { _ in model.handle(.toggleLaunchAtLogin) }))
            Picker(L("Language", "语言"),
                   selection: Binding(get: { model.language }, set: { model.handle(.setLanguage($0)) })) {
                Text(L("Same as System", "跟随系统")).tag(AppLanguage.system)
                Text("English").tag(AppLanguage.english)
                Text("中文").tag(AppLanguage.chinese)
            }
            Divider()
            Button(L("Clear History", "清空历史")) { model.handle(.clearHistory) }
                .disabled(model.history.isEmpty)
            Divider()
            Button(L("Check for Updates…", "检查更新…")) { model.handle(.checkForUpdates) }
            Text("ReTerm \(Updater.currentVersion)")
            Button(L("Quit ReTerm", "退出 ReTerm")) { model.handle(.quit) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Settings", "设置"))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionTitle(text: model.live.isEmpty ? L("Running", "正在运行")
                         : L("Running (\(model.live.count))", "正在运行（\(model.live.count)）"))
            if !model.loaded {
                Muted(text: L("Looking for Claude Code sessions…", "正在查找 Claude Code 会话…"))
            } else if model.live.isEmpty {
                Muted(text: L("No Claude Code sessions running", "没有正在运行的 Claude Code 会话"))
            }
            ForEach(model.live, id: \.sessionId) { session in
                LiveRow(session: session, model: model)
            }

            Divider().padding(.vertical, 6).padding(.horizontal, 6)

            if !model.pins.isEmpty {
                SectionTitle(text: L("Pinned (\(model.pins.count))", "已置顶（\(model.pins.count)）"))
                ForEach(model.pins, id: \.id) { entry in
                    HistoryRow(entry: entry, snapshot: nil, model: model)
                }
                Divider().padding(.vertical, 6).padding(.horizontal, 6)
            }

            if !model.history.isEmpty {
                ForEach(model.recent, id: \.id) { snapshot in
                    SnapshotSection(snapshot: snapshot, model: model)
                }
                if !model.earlier.isEmpty {
                    earlierToggle
                    if model.showEarlier {
                        ForEach(model.earlier, id: \.id) { snapshot in
                            SnapshotSection(snapshot: snapshot, model: model)
                        }
                    }
                }
            } else {
                SectionTitle(text: L("Finished & Closed", "已完成和已关闭"))
                Muted(text: L("Sessions you finish or close show up here, ready to reopen.",
                              "完成或关闭的会话会出现在这里，随时可以重新打开。"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
    }

    private var earlierToggle: some View {
        Button {
            model.showEarlier.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.showEarlier ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                Text(L("Earlier (\(model.earlier.count))", "更早（\(model.earlier.count)）"))
            }
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack {
            Button(L("Save & Close All Terminal Windows (\(model.openTabs))…",
                     "保存并关闭所有 Terminal 窗口（\(model.openTabs)）…")) {
                model.handle(.saveAndClose)
            }
            .disabled(model.openTabs == 0)
            .help(L("Record every Terminal tab, then close them all. Each one can be reopened from this panel.",
                    "记录所有 Terminal 标签页后全部关闭，之后每一个都能在这个面板里重新打开。"))
            Spacer()
            if model.isSnapshot {
                Text(L("Quit", "退出")).foregroundColor(.accentColor)
            } else {
                Button(L("Quit", "退出")) { model.handle(.quit) }
                    .buttonStyle(.borderless)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

// MARK: - Rows

struct LiveRow: View {
    let session: LiveSession
    @ObservedObject var model: PanelModel
    @StateObject private var hover = Flag()

    private var canJump: Bool {
        if case .unavailable = session.jump { return false }
        return true
    }

    private var place: String {
        ([session.hostLabel, session.hostDetail].compactMap { $0 }.joined(separator: " ")
            + (shortAge(session.statusSince, now: model.now).map { " · " + $0 } ?? ""))
    }

    private var tip: String {
        if case .unavailable(let reason) = session.jump { return reason + "\n" + session.cwd }
        return L("Click to bring its window to the front", "点击跳到它的窗口") + "\n" + session.cwd
    }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(status: session.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.shown(session.title, cwd: session.cwd))
                    .lineLimit(1)
                    .truncationMode(.tail)
                (Text(statusText(session))
                    .foregroundColor(session.status == .waiting ? .orange : .secondary)
                    + Text(" · " + place).foregroundColor(.secondary))
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            if model.isFinishable(session) {
                PillButton(symbol: "checkmark.circle", hoverSymbol: "checkmark.circle.fill",
                           title: L("Done", "完成"), tint: .green,
                           help: L("Finished: save this session and close its window. Reopen it any time from the list below.",
                                   "完成：保存这个会话并关闭它的窗口，之后可以在下面的列表里随时重新打开。")) {
                    model.handle(.finish(session))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover.on && canJump ? Color.primary.opacity(0.07) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { if canJump { model.handle(.jump(session)) } }
        .help(tip)
    }
}

struct SnapshotSection: View {
    let snapshot: Snapshot
    @ObservedObject var model: PanelModel

    var body: some View {
        let remaining = snapshot.entries.filter { !$0.reopened }.count
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionTitle(text: model.heading(snapshot))
                Spacer()
                if remaining > 1 {
                    Button(L("Reopen All (\(remaining))", "全部重新打开（\(remaining)）")) {
                        model.handle(.reopenAll(snapshot: snapshot.id))
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .padding(.trailing, 8)
                }
            }
            ForEach(snapshot.entries, id: \.id) { entry in
                HistoryRow(entry: entry, snapshot: snapshot.id, model: model)
            }
        }
    }
}

struct HistoryRow: View {
    let entry: Entry
    /// The group it is listed in; nil for a pinned entry.
    let snapshot: UUID?
    @ObservedObject var model: PanelModel
    @StateObject private var hover = Flag()

    private var open: PanelAction {
        snapshot.map { .reopen(snapshot: $0, entry: entry.id) } ?? .reopenPin(entry: entry.id)
    }

    private var openHelp: String {
        switch entry.kind {
        case "claude": return L("Reopen it in Terminal with the conversation resumed", "在 Terminal 里重新打开，并恢复对话")
        case "codex": return L("Reopen it in Terminal with the Codex session resumed", "在 Terminal 里重新打开，并恢复 Codex 会话")
        default: return L("Open a shell in this folder", "在这个文件夹里打开一个 shell")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: snapshot == nil ? "pin.fill" : entry.symbol)
                .font(.system(size: 11))
                .foregroundColor(snapshot == nil ? .orange : .secondary)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.shown(entry.title, cwd: entry.cwd))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.shortPath)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            if entry.reopened {
                Image(systemName: "checkmark")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .help(L("Already reopened", "已经重新打开过"))
            }
            PillButton(symbol: "arrow.uturn.backward.circle", hoverSymbol: "arrow.uturn.backward.circle.fill",
                       title: L("Open", "打开"), tint: .accentColor, help: openHelp) {
                model.handle(open)
            }
        }
        .opacity(entry.reopened ? 0.6 : 1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover.on ? Color.primary.opacity(0.07) : Color.clear))
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
        .onTapGesture { model.handle(open) }
        .help(entry.cwd)
    }
}

// MARK: - Pieces

struct PillButton: View {
    let symbol: String
    let hoverSymbol: String
    let title: String
    let tint: Color
    let help: String
    let action: () -> Void
    @StateObject private var hover = Flag()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: hover.on ? hoverSymbol : symbol)
                Text(title)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .foregroundColor(hover.on ? tint : .secondary)
            .background(Capsule().fill(hover.on ? tint.opacity(0.16) : Color.primary.opacity(0.06)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .help(help)
    }
}

struct StatusDot: View {
    let status: LiveStatus

    var body: some View {
        Group {
            switch status {
            case .fresh, .unknown:
                Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
            case .waiting:
                Circle().fill(Color.orange)
            case .idle:
                Circle().fill(Color.green)
            case .busy:
                Circle().fill(Color.blue)
            case .shell:
                Circle().fill(Color.teal)
            }
        }
        .frame(width: 9, height: 9)
        .frame(width: 14)
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}

struct Muted: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
    }
}

/// A scroll view as tall as its content, up to `maxHeight`, so a short panel has no empty space.
struct FittingScroll<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: Content
    @StateObject private var measured = Measured()

    var body: some View {
        ScrollView(.vertical) {
            content.background(GeometryReader { proxy in
                Color.clear.preference(key: ContentHeight.self, value: proxy.size.height)
            })
        }
        .frame(height: min(measured.height, maxHeight))
        .onPreferenceChange(ContentHeight.self) { measured.height = $0 }
    }
}

/// View state kept in objects: the Command Line Tools have no plugin for SwiftUI's @State macro.
final class Flag: ObservableObject {
    @Published var on = false
}

final class Measured: ObservableObject {
    @Published var height: CGFloat = 120
}

private struct ContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Picture of the panel (development aid)

/// --render-panel <out.png> [--dark] [--sample]: draws the panel to a PNG, with live data or sample data.
@MainActor
func renderPanel(to path: String, dark: Bool, sample: Bool) -> Bool {
    let model = PanelModel()
    model.isSnapshot = true
    model.loaded = true
    if sample {
        let now = Date()
        func s(_ title: String, _ status: LiveStatus, _ host: HostKind, _ label: String, _ detail: String?, _ minutes: Double,
               waiting: String? = nil, jump: Jump? = nil) -> LiveSession {
            LiveSession(pid: 1, sessionId: UUID().uuidString, title: title, cwd: "/Users/me/Projects/\(title.prefix(8))",
                        status: status, waitingFor: waiting, statusSince: now.addingTimeInterval(-minutes * 60),
                        hostKind: host, hostLabel: label, hostDetail: detail,
                        jump: jump ?? .terminal(app: "Terminal", tty: "/dev/ttys001"))
        }
        model.live = [
            s("Fix the login redirect bug", .waiting, .terminal, "Terminal", "ttys003", 4, waiting: "permission prompt"),
            s("A very long session title that goes on and on to check how truncation looks in the panel", .idle,
              .terminal, "Terminal", "ttys001", 12),
            s("周报整理", .idle, .desktop, "Claude App", nil, 2, jump: .url(url: "claude://", fallback: nil)),
            s("Refactor the parser", .busy, .editor, "VS Code", "parser", 1,
              jump: .editor(appPath: "/Applications/Visual Studio Code.app", cli: "code", folder: "/x")),
            s("Running tests", .shell, .terminal, "Terminal", "ttys004", 0.2),
            s("New session", .fresh, .tmux, "tmux", nil, 0, jump: .unavailable(reason: "tmux")),
        ]
        var finished = Snapshot(closed: true, entries: [], finished: true)
        finished.entries = [
            Entry(kind: "claude", cwd: "/Users/me/Codex/ReTerm", tty: "", sessionId: "a", topic: "ReTerm live sessions"),
            Entry(kind: "claude", cwd: "/Users/me/Teaching/VCE", tty: "", sessionId: "b", reopened: true, topic: "VCE 练习卷"),
        ]
        let closed = Snapshot(date: now.addingTimeInterval(-50 * 3600), closed: true, entries: [
            Entry(kind: "shell", cwd: "/Users/me/Downloads", tty: ""),
        ])
        let auto = Snapshot(date: now.addingTimeInterval(-1800), closed: true, entries: [
            Entry(kind: "claude", cwd: "/Users/me/Projects/site", tty: "", sessionId: "d", topic: "Fix the nav bar on mobile"),
        ], auto: true)
        var older = closed
        older.id = UUID()
        model.history = [finished, auto, closed, older]
        model.pins = [Entry(kind: "codex", cwd: "/Users/me/Projects/api", tty: "", sessionId: "c", topic: "API rate limiter")]
        model.openTabs = 3
    } else {
        model.history = History.loadFillingTopics()
        model.pins = Pins.load()
        model.live = scanLiveSessions(includeTitles: !model.hideTitles)
        model.openTabs = detectTerminalTabs(includeTopics: false, codexSessions: false).count
    }
    let view = PanelView(model: model)
        .background(dark ? Color(white: 0.17) : Color(white: 0.96))
        .environment(\.colorScheme, dark ? .dark : .light)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.cgImage else { return false }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { return false }
    return (try? png.write(to: URL(fileURLWithPath: path))) != nil
}
