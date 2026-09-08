// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import SwiftUI

struct CommandBarJSONResultView: NSViewRepresentable {
    let document: CommandBarJSONDocument
    func makeNSView(context: Context) -> CommandBarJSONOutlinePanel { CommandBarJSONOutlinePanel() }
    func updateNSView(_ view: CommandBarJSONOutlinePanel, context: Context) { view.setDocument(document) }
}

private final class JSONSearchOperation: Operation, @unchecked Sendable {
    let document: CommandBarJSONDocument
    let query: String
    let completion: ([Int]) -> Void
    init(document: CommandBarJSONDocument, query: String, completion: @escaping ([Int]) -> Void) {
        self.document = document; self.query = query; self.completion = completion
    }
    override func main() {
        let result = document.matches(query, cancelled: { self.isCancelled })
        guard !isCancelled else { return }
        DispatchQueue.main.async { [self] in
            guard !self.isCancelled else { return }
            self.completion(result)
        }
    }
}

final class CommandBarJSONOutlinePanel: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    private let outline = NSOutlineView()
    private let search = NSSearchField()
    private let count = NSTextField(labelWithString: "")
    private let queue = OperationQueue()
    private var document: CommandBarJSONDocument?
    private var items: [NSNumber] = []
    private var matches: [Int] = []
    private var matchIndex = -1
    private var revision = UUID()
    private let t = CommandBarDeveloperText.text

    init() {
        super.init(frame: .zero)
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        search.placeholderString = t("搜索键名或值", "Search keys or values")
        search.delegate = self
        search.sendsSearchStringImmediately = false
        search.setContentHuggingPriority(.defaultLow, for: .horizontal)
        count.font = .systemFont(ofSize: 11)
        let previous = NSButton(title: "↑", target: self, action: #selector(previousMatch))
        previous.toolTip = t("上一个匹配", "Previous match")
        let next = NSButton(title: "↓", target: self, action: #selector(nextMatch))
        next.toolTip = t("下一个匹配", "Next match")
        let expand = NSButton(title: t("展开选中", "Expand selected"), target: self, action: #selector(expandSelected))
        let collapse = NSButton(title: t("全部收起", "Collapse all"), target: self, action: #selector(collapseAll))
        let bar = NSStackView(views: [search, count, previous, next, expand, collapse])
        bar.spacing = 6
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        key.title = t("键 / 索引", "Key / index"); key.width = 240
        let value = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        value.title = t("值", "Value"); value.width = 460
        outline.addTableColumn(key); outline.addTableColumn(value)
        outline.outlineTableColumn = key
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.rowHeight = 23
        outline.usesAlternatingRowBackgroundColors = true
        outline.dataSource = self; outline.delegate = self
        scroll.documentView = outline
        for child in [bar, scroll] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor), bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor), bar.heightAnchor.constraint(equalToConstant: 30),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor), search.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
        ])
    }
    required init?(coder: NSCoder) { nil }
    deinit { queue.cancelAllOperations() }

    func setDocument(_ value: CommandBarJSONDocument) {
        guard document !== value else { return }
        queue.cancelAllOperations(); revision = UUID()
        document = value
        items = value.nodes.indices.map { NSNumber(value: $0) }
        outline.reloadData()
        if let root = items.first { outline.expandItem(root) }
        startSearch()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let document else { return 0 }
        guard let item = item as? NSNumber else { return 1 }
        return document.nodes[item.intValue].children.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let item = item as? NSNumber, let document else { return items[0] }
        return items[document.nodes[item.intValue].children[index]]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? NSNumber, let document else { return false }
        return !document.nodes[item.intValue].children.isEmpty
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let id = item as? NSNumber, let document, let identifier = tableColumn?.identifier else { return nil }
        let label = (outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        label.identifier = identifier
        label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        label.lineBreakMode = .byTruncatingTail
        let node = document.nodes[id.intValue]
        label.stringValue = identifier.rawValue == "key" ? String(node.key.prefix(500)) : node.summary
        label.toolTip = label.stringValue
        label.textColor = node.container ? .secondaryLabelColor : .labelColor
        return label
    }
    func controlTextDidChange(_ obj: Notification) { startSearch() }
    private func startSearch() {
        queue.cancelAllOperations()
        revision = UUID()
        matches = []; matchIndex = -1
        let query = search.stringValue
        guard let document, !query.isEmpty else { count.stringValue = ""; return }
        count.stringValue = t("搜索中…", "Searching…")
        let token = revision
        let operation = JSONSearchOperation(document: document, query: query) { [weak self] matches in
            guard let self, self.revision == token else { return }
            self.matches = matches
            self.moveMatch(by: 1)
        }
        queue.addOperation(operation)
    }
    @objc private func nextMatch() { moveMatch(by: 1) }
    @objc private func previousMatch() { moveMatch(by: -1) }
    private func moveMatch(by delta: Int) {
        guard let document, !matches.isEmpty else { count.stringValue = "0 / 0"; return }
        matchIndex = (matchIndex + delta + matches.count) % matches.count
        let id = matches[matchIndex]
        for ancestor in document.ancestors(of: id) { outline.expandItem(items[ancestor]) }
        let row = outline.row(forItem: items[id])
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row) }
        count.stringValue = "\(matchIndex + 1) / \(matches.count)"
    }
    @objc private func expandSelected() {
        if let item = outline.item(atRow: outline.selectedRow) { outline.expandItem(item) }
        else if let root = items.first { outline.expandItem(root) }
    }
    @objc private func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }
}
