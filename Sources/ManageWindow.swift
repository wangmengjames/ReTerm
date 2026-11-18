import AppKit

/// A searchable list of everything ReTerm remembers, with Reopen, Pin and Delete.
final class ManageWindowController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = ManageWindowController()

    struct Row {
        let entry: Entry
        let pinned: Bool        // a row from the pinned list (as opposed to history)
        let date: Date?
    }

    private(set) var window: NSWindow?
    private let table = NSTableView()
    private let search = NSSearchField()
    private let reopenButton = NSButton()
    private let pinButton = NSButton()
    private let deleteButton = NSButton()
    private let hint = NSTextField(labelWithString: "")
    private var all: [Row] = []
    private var rows: [Row] = []
    private var pinnedKeys: Set<String> = []
    /// Called after anything is reopened, pinned or deleted, so the panel can catch up.
    var onChange: () -> Void = {}

    func show() {
        build()
        reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(search)
    }

    /// Whether Hide Session Titles is on; the app points this at the panel's own setting.
    var hideTitles: () -> Bool = { false }

    /// Hide Session Titles was switched: only what the rows show changes, and only if they are on screen.
    func settingsChanged() {
        guard window?.isVisible == true else { return }
        applyFilter()
    }

    private func shownTitle(_ entry: Entry) -> String {
        displayTitle(entry.title, cwd: entry.cwd, hidden: hideTitles())
    }

    func languageChanged() {
        guard window != nil else { return }
        applyLanguage()
        reload()
    }

    // MARK: Building

    func build() {
        guard window == nil else { return }
        let size = NSSize(width: 760, height: 480)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 560, height: 320)
        let content = w.contentView!

        search.frame = NSRect(x: 16, y: size.height - 44, width: size.width - 32, height: 28)
        search.autoresizingMask = [.width, .minYMargin]
        search.delegate = self
        content.addSubview(search)

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 56, width: size.width - 32, height: size.height - 112))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        for (id, width) in [("kind", 30.0), ("title", 300.0), ("folder", 250.0), ("when", 120.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            column.minWidth = id == "kind" ? 30 : 80
            if id == "kind" { column.maxWidth = 30 }
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.target = self
        table.doubleAction = #selector(reopenClicked)
        scroll.documentView = table
        content.addSubview(scroll)

        var x: CGFloat = 16
        for (button, action) in [(reopenButton, #selector(reopenSelected)), (pinButton, #selector(pinSelected)), (deleteButton, #selector(deleteSelected))] {
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.frame = NSRect(x: x, y: 14, width: 130, height: 30)
            button.autoresizingMask = [.maxXMargin, .maxYMargin]
            content.addSubview(button)
            x += 138
        }
        hint.frame = NSRect(x: x + 4, y: 20, width: size.width - x - 20, height: 18)
        hint.autoresizingMask = [.width, .maxYMargin]
        hint.textColor = .secondaryLabelColor
        hint.font = .systemFont(ofSize: 11)
        hint.lineBreakMode = .byTruncatingTail
        content.addSubview(hint)

        window = w
        applyLanguage()
    }

    private func applyLanguage() {
        window?.title = L("ReTerm: Search & Manage", "ReTerm：搜索与管理")
        search.placeholderString = L("Search by title or folder", "按标题或文件夹搜索")
        reopenButton.title = L("Reopen", "重新打开")
        deleteButton.title = L("Delete", "删除")
        hint.stringValue = L("Double-click a row to reopen it.", "双击一行即可重新打开。")
        let titles = ["kind": "", "title": L("Title", "标题"), "folder": L("Folder", "文件夹"), "when": L("Closed", "关闭时间")]
        for column in table.tableColumns { column.title = titles[column.identifier.rawValue] ?? "" }
        updateButtons()
    }

    // MARK: Data

    func reload() {
        let pins = Pins.load()
        pinnedKeys = Set(pins.map(\.pinKey))
        all = pins.map { Row(entry: $0, pinned: true, date: nil) }
        for snapshot in History.loadFillingTopics() {
            all += snapshot.entries.map { Row(entry: $0, pinned: false, date: snapshot.date) }
        }
        applyFilter()
    }

    private func applyFilter() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        rows = query.isEmpty ? all : all.filter {
            shownTitle($0.entry).lowercased().contains(query) || $0.entry.cwd.lowercased().contains(query)
        }
        table.reloadData()
        updateButtons()
    }

    func controlTextDidChange(_ notification: Notification) { applyFilter() }

    private var selection: [Row] {
        table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    private func updateButtons() {
        let picked = selection
        reopenButton.isEnabled = !picked.isEmpty
        deleteButton.isEnabled = !picked.isEmpty
        pinButton.isEnabled = !picked.isEmpty
        let allPinned = !picked.isEmpty && picked.allSatisfy { pinnedKeys.contains($0.entry.pinKey) }
        pinButton.title = allPinned ? L("Unpin", "取消置顶") : L("Pin", "置顶")
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let column = tableColumn?.identifier.rawValue else { return nil }
        let item = rows[row]
        if column == "kind" {
            let symbol = item.pinned ? "pin.fill" : item.entry.symbol
            let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: item.entry.kind) ?? NSImage())
            image.contentTintColor = item.pinned ? .systemOrange : .secondaryLabelColor
            return image
        }
        let text: String
        switch column {
        case "title": text = shownTitle(item.entry)
        case "folder": text = item.entry.shortPath
        default:
            if item.pinned {
                text = L("Pinned", "已置顶")
            } else if let date = item.date {
                let formatter = RelativeDateTimeFormatter()
                formatter.locale = Lang.locale
                text = formatter.localizedString(for: date, relativeTo: Date()) + (item.entry.reopened ? "  ✓" : "")
            } else {
                text = ""
            }
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.textColor = column == "title" ? .labelColor : .secondaryLabelColor
        let cell = NSTableCellView()
        label.frame = NSRect(x: 2, y: 3, width: (tableColumn?.width ?? 100) - 4, height: 18)
        label.autoresizingMask = [.width]
        cell.addSubview(label)
        cell.textField = label
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    // MARK: Actions

    @objc private func reopenClicked() {
        // The double-click action also fires on a column header, where there is no clicked row.
        let index = table.clickedRow
        guard index >= 0, index < rows.count else { return }
        reopenRows([rows[index]])
    }

    @objc private func reopenSelected() { reopenRows(selection) }

    private func reopenRows(_ picked: [Row]) {
        for (index, row) in picked.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.4) {
                if reopen(row.entry), !row.pinned { History.markReopened(entry: row.entry.id) }
                if index == picked.count - 1 {
                    self.reload()
                    self.onChange()
                }
            }
        }
    }

    @objc private func pinSelected() {
        let picked = selection
        let allPinned = picked.allSatisfy { pinnedKeys.contains($0.entry.pinKey) }
        var seen: Set<String> = []
        for row in picked where seen.insert(row.entry.pinKey).inserted {
            // Pin what is not pinned yet; if everything already is, unpin it all.
            if allPinned || !pinnedKeys.contains(row.entry.pinKey) { Pins.toggle(row.entry) }
        }
        reload()
        onChange()
    }

    @objc private func deleteSelected() {
        for row in selection {
            if row.pinned {
                Pins.toggle(row.entry)
            } else {
                History.delete(entry: row.entry.id)
            }
        }
        reload()
        onChange()
    }
}
