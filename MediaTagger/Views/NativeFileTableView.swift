import SwiftUI
import AppKit

struct NativeFileTableView: NSViewRepresentable {
    let rows: [FileListRow]
    @Binding var selection: Set<URL>
    let icon: (String) -> String
    let menuEntries: (Set<URL>) -> [BrowserMenuEntry]
    let onSortChanged: (FileListSortField, Bool) -> Void
    var sortField: FileListSortField = .track
    var sortAscending = true
    var canImportImages = false
    var onImagesDropped: ([DroppedImageSource]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        let table = FileBrowserTableView()
        for identifier in ["track", "file", "title"] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = identifier == "track" ? "#" : identifier.capitalized
            column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: true)
            if identifier == "track" {
                column.width = 60
                column.minWidth = 50
                column.resizingMask = .userResizingMask
                column.headerToolTip = "Sort by track number"
            } else {
                column.width = 240
                column.minWidth = identifier == "file" ? 100 : 80
            }
            table.addTableColumn(column)
        }
        table.headerView = FileBrowserHeaderView(frame: NSRect(x: 0, y: 0, width: 0, height: 28))
        table.allowsColumnResizing = true
        table.allowsColumnReordering = false
        table.rowHeight = 24
        table.style = .plain
        table.focusRingType = .none
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.registerForDraggedTypes(DroppedImageImporter.pasteboardTypes)
        table.fileMenu = { [weak coordinator = context.coordinator] row in
            coordinator?.menu(at: row)
        }
        scrollView.documentView = table
        context.coordinator.update(self, table: table)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let table = nsView.documentView as? FileBrowserTableView else {
            preconditionFailure("File browser requires its table view.")
        }
        context.coordinator.update(self, table: table)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        private var parent: NativeFileTableView
        private var displayedRows: [FileListRow] = []
        private var updatingSelection = false

        init(parent: NativeFileTableView) { self.parent = parent }

        func update(_ parent: NativeFileTableView, table: NSTableView) {
            self.parent = parent
            updatingSelection = true
            defer { updatingSelection = false }
            if displayedRows != parent.rows {
                displayedRows = parent.rows
                table.reloadData()
            }
            let indexes = IndexSet(displayedRows.indices.filter { parent.selection.contains(displayedRows[$0].id) })
            if indexes != table.selectedRowIndexes {
                table.selectRowIndexes(indexes, byExtendingSelection: false)
            }
            let descriptors = [NSSortDescriptor(key: parent.sortField.rawValue, ascending: parent.sortAscending)]
            if table.sortDescriptors != descriptors { table.sortDescriptors = descriptors }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { displayedRows.count }

        func tableView(
            _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
            proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            guard parent.canImportImages,
                  !DroppedImageImporter.sources(from: info.draggingPasteboard).isEmpty else { return [] }
            tableView.setDropRow(-1, dropOperation: .above)
            return .copy
        }

        func tableView(
            _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
            row: Int, dropOperation: NSTableView.DropOperation
        ) -> Bool {
            guard parent.canImportImages else { return false }
            let sources = DroppedImageImporter.sources(from: info.draggingPasteboard)
            guard !sources.isEmpty else { return false }
            parent.onImagesDropped(sources)
            return true
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updatingSelection, let descriptor = tableView.sortDescriptors.first else { return }
            guard let key = descriptor.key, let field = FileListSortField(rawValue: key) else {
                preconditionFailure("Unknown file browser sort field.")
            }
            parent.onSortChanged(field, descriptor.ascending)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard displayedRows.indices.contains(row), let column = tableColumn else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("\(column.identifier.rawValue)Cell")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.translatesAutoresizingMaskIntoConstraints = false
                text.lineBreakMode = .byTruncatingTail
                cell.addSubview(text)
                cell.textField = text
                if column.identifier.rawValue == "file" {
                    let image = NSImageView()
                    image.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(image)
                    cell.imageView = image
                    NSLayoutConstraint.activate([
                        image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
                        image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        image.widthAnchor.constraint(equalToConstant: 16),
                        image.heightAnchor.constraint(equalToConstant: 16),
                        text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 5)
                    ])
                } else {
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8).isActive = true
                }
                NSLayoutConstraint.activate([
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            let value = displayedRows[row]
            switch column.identifier.rawValue {
            case "track":
                cell.textField?.stringValue = value.track
                cell.textField?.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
                cell.textField?.textColor = .secondaryLabelColor
            case "file":
                cell.textField?.stringValue = value.file.name
                cell.textField?.textColor = .labelColor
                cell.imageView?.image = NSImage(
                    systemSymbolName: parent.icon(value.file.ext), accessibilityDescription: nil
                )
                cell.imageView?.contentTintColor = .controlAccentColor
            case "title":
                cell.textField?.stringValue = value.title ?? "—"
                cell.textField?.textColor = value.title == nil ? .secondaryLabelColor : .labelColor
            default:
                preconditionFailure("Unknown file browser column.")
            }
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updatingSelection, let table = notification.object as? NSTableView else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { index in
                displayedRows.indices.contains(index) ? displayedRows[index].id : nil
            })
            if parent.selection != ids { parent.selection = ids }
        }

        func menu(at row: Int) -> NSMenu {
            var targets = parent.selection
            if displayedRows.indices.contains(row), !targets.contains(displayedRows[row].id) {
                targets = [displayedRows[row].id]
            }
            return makeBrowserMenu(parent.menuEntries(targets))
        }
    }
}

final class FileBrowserTableView: NSTableView {
    var fileMenu: ((Int) -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }

    private func isSelectAll(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers?.lowercased() == "a" &&
            event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if isSelectAll(event) {
            guard window?.firstResponder === self else { return false }
            selectAll(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if isSelectAll(event) {
            selectAll(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        fileMenu?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

final class FileBrowserHeaderView: NSTableHeaderView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if let tableView { window?.makeFirstResponder(tableView) }
        super.mouseDown(with: event)
        if let tableView { window?.makeFirstResponder(tableView) }
    }
}
