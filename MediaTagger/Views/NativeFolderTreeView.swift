import SwiftUI
import AppKit

struct NativeFolderTreeView: NSViewRepresentable {
    let root: FolderNode
    @Binding var selection: URL?
    let menuEntries: (URL) -> [BrowserMenuEntry]

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let outline = FolderOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        column.width = 260
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 24
        outline.indentationPerLevel = 16
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.allowsMultipleSelection = false
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.autoresizesOutlineColumn = true
        outline.autoresizingMask = [.width]
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.arrowKeyHandler = { [weak coordinator = context.coordinator, weak outline] code in
            guard let outline else { return }
            coordinator?.handleArrow(code, in: outline)
        }
        outline.folderMenu = { [weak coordinator = context.coordinator] url in
            coordinator?.menu(for: url)
        }
        scrollView.documentView = outline
        context.coordinator.update(self, outline: outline)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let outline = nsView.documentView as? FolderOutlineView else {
            preconditionFailure("Folder tree requires its outline view.")
        }
        context.coordinator.update(self, outline: outline)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        private var parent: NativeFolderTreeView
        private var displayedRoot: FolderNode?
        private var navigation = FolderTreeNavigation()
        private var updatingSelection = false

        init(parent: NativeFolderTreeView) { self.parent = parent }

        func update(_ parent: NativeFolderTreeView, outline: NSOutlineView) {
            self.parent = parent
            updatingSelection = true
            defer { updatingSelection = false }
            if displayedRoot !== parent.root {
                outline.collapseItem(nil, collapseChildren: true)
                displayedRoot = parent.root
                navigation = FolderTreeNavigation()
                outline.reloadData()
            }
            if let row = navigation.visibleRows(root: parent.root).first(where: { $0.id == parent.selection }) {
                let index = outline.row(forItem: row.node)
                if index >= 0, outline.selectedRow != index {
                    outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                }
            } else if outline.selectedRow >= 0 {
                outline.deselectAll(nil)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            guard let node = item as? FolderNode else { return 1 }
            return node.children?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            guard let node = item as? FolderNode else { return parent.root }
            guard let children = node.children else {
                preconditionFailure("Only expandable folders have child rows.")
            }
            return children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? FolderNode)?.children != nil
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FolderNode else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("folderCell")
            let cell: NSTableCellView
            if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let image = NSImageView()
                let text = NSTextField(labelWithString: "")
                image.translatesAutoresizingMaskIntoConstraints = false
                text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingMiddle
                cell.addSubview(image)
                cell.addSubview(text)
                cell.imageView = image
                cell.textField = text
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            cell.textField?.stringValue = node.url.lastPathComponent
            cell.imageView?.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Folder")
            cell.imageView?.contentTintColor = .controlAccentColor
            cell.toolTip = node.url.path
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let outline = notification.object as? NSOutlineView,
                  let node = outline.item(atRow: outline.selectedRow) as? FolderNode else { return }
            if parent.selection != node.url { parent.selection = node.url }
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? FolderNode {
                navigation.expandedURLs.insert(node.url)
            }
            if !updatingSelection, let outline = notification.object as? NSOutlineView {
                outline.window?.makeFirstResponder(outline)
            }
        }

        func outlineViewItemWillCollapse(_ notification: Notification) {
            guard !updatingSelection, let outline = notification.object as? NSOutlineView,
                  let node = notification.userInfo?["NSObject"] as? FolderNode else { return }
            if navigation.visibleRows(root: node).dropFirst().contains(where: { $0.id == parent.selection }) {
                let row = outline.row(forItem: node)
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            if let node = notification.userInfo?["NSObject"] as? FolderNode {
                navigation.expandedURLs.remove(node.url)
            }
            if !updatingSelection, let outline = notification.object as? NSOutlineView {
                outline.window?.makeFirstResponder(outline)
            }
        }

        func handleArrow(_ code: UInt16, in outline: NSOutlineView) {
            let node = outline.item(atRow: outline.selectedRow) as? FolderNode
            let selection: URL?
            if code == 125 || code == 126 {
                selection = navigation.moveVertically(
                    root: parent.root, selection: node?.url, offset: code == 125 ? 1 : -1
                )
            } else {
                selection = navigation.moveHorizontally(
                    root: parent.root, selection: node?.url, expanding: code == 124
                )
                if let node {
                    if navigation.expandedURLs.contains(node.url) {
                        outline.expandItem(node)
                    } else {
                        outline.collapseItem(node)
                    }
                }
            }
            let visible = navigation.visibleRows(root: parent.root)
            guard let target = visible.first(where: { $0.id == selection }) else { return }
            let index = outline.row(forItem: target.node)
            guard index >= 0 else { return }
            outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            outline.scrollRowToVisible(index)
        }

        func menu(for url: URL) -> NSMenu {
            makeBrowserMenu(parent.menuEntries(url))
        }
    }
}

final class FolderOutlineView: NSOutlineView {
    var arrowKeyHandler: ((UInt16) -> Void)?
    var folderMenu: ((URL) -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if (123...126).contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           let arrowKeyHandler {
            arrowKeyHandler(event.keyCode)
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0, let node = item(atRow: row) as? FolderNode else { return nil }
        return folderMenu?(node.url)
    }
}
