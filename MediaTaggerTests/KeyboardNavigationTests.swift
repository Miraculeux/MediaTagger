import XCTest
import SwiftUI
@testable import MediaTagger

final class KeyboardNavigationTests: XCTestCase {
    private var root: FolderNode!
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("a/child"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("b"), withIntermediateDirectories: true
        )
        directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).first).deletingLastPathComponent()
        root = FolderNode(url: directory)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testOnlyExpandedDescendantsAreVisibleInDirectoryOrder() {
        var navigation = FolderTreeNavigation()
        XCTAssertEqual(navigation.visibleRows(root: root).map(\.id), [directory])
        navigation.expandedURLs.insert(directory)
        let a = directory.appendingPathComponent("a", isDirectory: true)
        let b = directory.appendingPathComponent("b", isDirectory: true)
        XCTAssertEqual(navigation.visibleRows(root: root).map(\.id), [directory, a, b])
        navigation.expandedURLs.insert(a)
        XCTAssertEqual(navigation.visibleRows(root: root).map(\.depth), [0, 1, 2, 1])
        navigation.expandedURLs.remove(directory)
        XCTAssertEqual(navigation.visibleRows(root: root).map(\.id), [directory])
    }

    func testRightExpandsThenEntersFirstChildAndLeftCollapsesThenSelectsParent() {
        var navigation = FolderTreeNavigation()
        let a = directory.appendingPathComponent("a", isDirectory: true)
        XCTAssertEqual(navigation.moveHorizontally(root: root, selection: directory, expanding: true), directory)
        XCTAssertTrue(navigation.expandedURLs.contains(directory))
        XCTAssertEqual(navigation.moveHorizontally(root: root, selection: directory, expanding: true), a)
        XCTAssertEqual(navigation.moveHorizontally(root: root, selection: a, expanding: true), a)
        XCTAssertTrue(navigation.expandedURLs.contains(a))
        XCTAssertEqual(navigation.moveHorizontally(root: root, selection: a, expanding: false), a)
        XCTAssertFalse(navigation.expandedURLs.contains(a))
        XCTAssertEqual(navigation.moveHorizontally(root: root, selection: a, expanding: false), directory)
    }

    func testLeafAndRootBoundariesAndMissingSelection() {
        var navigation = FolderTreeNavigation()
        XCTAssertEqual(navigation.moveHorizontally(root: root, selection: nil, expanding: true), directory)
        XCTAssertEqual(navigation.moveHorizontally(root: root, selection: directory, expanding: false), directory)
        navigation.expandedURLs.insert(directory)
        let leaf = directory.appendingPathComponent("b", isDirectory: true)
        XCTAssertEqual(navigation.moveHorizontally(root: root, selection: leaf, expanding: true), leaf)
        XCTAssertFalse(navigation.expandedURLs.contains(leaf))
        XCTAssertEqual(navigation.moveHorizontally(root: root, selection: leaf, expanding: false), directory)
    }

    func testVerticalNavigationUsesVisibleRowsAndStopsAtBoundaries() {
        var navigation = FolderTreeNavigation()
        navigation.expandedURLs.insert(directory)
        let a = directory.appendingPathComponent("a", isDirectory: true)
        let b = directory.appendingPathComponent("b", isDirectory: true)
        XCTAssertEqual(navigation.moveVertically(root: root, selection: directory, offset: -1), directory)
        XCTAssertEqual(navigation.moveVertically(root: root, selection: directory, offset: 1), a)
        XCTAssertEqual(navigation.moveVertically(root: root, selection: a, offset: 1), b)
        XCTAssertEqual(navigation.moveVertically(root: root, selection: b, offset: 1), b)
        navigation.expandedURLs.insert(a)
        XCTAssertEqual(navigation.moveVertically(root: root, selection: a, offset: 1),
                       a.appendingPathComponent("child", isDirectory: true))
        XCTAssertEqual(navigation.moveVertically(root: root, selection: nil, offset: 1), directory)
        XCTAssertEqual(navigation.moveVertically(root: root, selection: nil, offset: -1), b)
    }

    func testFilteredRootsExcludeMatchingDescendantsButKeepFullSubtrees() throws {
        let album = directory.appendingPathComponent(
            "Brahms-The 4 Symphonies, Claudio Abbado - (2018) [3SACD]", isDirectory: true
        )
        let matchingChild = album.appendingPathComponent("Claudio Abbado - Brahms SACD 1", isDirectory: true)
        let otherChild = album.appendingPathComponent("Disc 2", isDirectory: true)
        let unrelated = directory.appendingPathComponent("a/Brahms - Violin Concerto", isDirectory: true)
        for folder in [matchingChild, otherChild, unrelated] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let results = root.matchingRoots(query: "BRAHMS", limit: 500)
        XCTAssertEqual(results.map(\.url), [album, unrelated])
        XCTAssertEqual(root.matchingRoots(query: "brahms", limit: 1).map(\.url), [album])
        XCTAssertTrue(root.matchingRoots(query: "no such folder", limit: 500).isEmpty)
        XCTAssertTrue(root.matchingRoots(query: "brahms", limit: 0).isEmpty)
        XCTAssertEqual(root.matchingRoots(query: "sacd 1", limit: 500).map(\.url), [matchingChild])
        var navigation = FolderTreeNavigation()
        XCTAssertEqual(navigation.visibleRows(roots: results).map(\.id), [album, unrelated])
        XCTAssertEqual(navigation.moveHorizontally(roots: results, selection: album, expanding: true), album)
        XCTAssertEqual(navigation.visibleRows(roots: results).map(\.id), [album, matchingChild, otherChild, unrelated])
        XCTAssertEqual(navigation.moveVertically(roots: results, selection: otherChild, offset: 1), unrelated)
        XCTAssertEqual(navigation.moveHorizontally(roots: results, selection: otherChild, expanding: false), album)
        XCTAssertEqual(navigation.moveHorizontally(roots: results, selection: album, expanding: false), album)
        XCTAssertEqual(navigation.visibleRows(roots: results).map(\.id), [album, unrelated])
        XCTAssertNil(navigation.moveVertically(roots: [], selection: nil, offset: 1))
        XCTAssertNil(navigation.moveHorizontally(roots: [], selection: nil, expanding: true))
    }

    @MainActor
    func testFilteredSidebarExpandsAllChildrenAndLoadsFilesWithKeyboardAndDisclosure() async throws {
        let album = directory.appendingPathComponent(
            "Brahms-The 4 Symphonies, Claudio Abbado - (2018) [3SACD]", isDirectory: true
        )
        let disc = album.appendingPathComponent("Disc 1", isDirectory: true)
        let matchingDisc = album.appendingPathComponent("Claudio Abbado - Brahms SACD 2", isDirectory: true)
        for folder in [disc, matchingDisc] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let file = disc.appendingPathComponent("track.mp3")
        try Data("FAKEMP3DATA".utf8).write(to: file)
        try ID3v2File.write(url: file, entries: [("TITLE", "Symphony")], cover: nil)
        let state = AppState(metadataWriter: { _, _ in })
        state.rootURL = directory
        state.selectedFolder = album
        let window = await host(SidebarView().environmentObject(state))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let search = try XCTUnwrap(textField(in: content))
        XCTAssertTrue(window.makeFirstResponder(search))
        try sendKey("brahms", code: 11, to: window)
        await settle()
        let outline = try XCTUnwrap(table(in: content) as? FolderOutlineView)
        XCTAssertEqual(outline.numberOfRows, 1)
        XCTAssertEqual((outline.item(atRow: 0) as? FolderNode)?.url, album)
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? FolderTreeCellView)
        XCTAssertEqual(cell.pathLabel.stringValue, album.lastPathComponent)
        XCTAssertEqual(outline.folderMenu?(album)?.item(at: 0)?.title, "Reveal in Finder")
        try click(outline.rect(ofRow: 0), in: outline, window: window)
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        XCTAssertEqual(outline.numberOfRows, 3)
        XCTAssertEqual((outline.item(atRow: 1) as? FolderNode)?.url, matchingDisc)
        XCTAssertEqual((outline.item(atRow: 2) as? FolderNode)?.url, disc)
        XCTAssertTrue(window.firstResponder === outline)
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, matchingDisc)
        try sendKey("\u{f701}", code: 125, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, disc)
        XCTAssertEqual(state.files.map(\.url), [file])
        XCTAssertEqual(search.stringValue, "brahms")
        try sendKey("\u{f702}", code: 123, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, album)
        let row = try XCTUnwrap(outline.rowView(atRow: 0, makeIfNecessary: true))
        let disclosure = try XCTUnwrap(button(in: row))
        disclosure.performClick(nil)
        await settle()
        XCTAssertEqual(outline.numberOfRows, 1)
        disclosure.performClick(nil)
        await settle()
        XCTAssertEqual(outline.numberOfRows, 3)
        XCTAssertTrue(window.firstResponder === outline)
        XCTAssertTrue(window.makeFirstResponder(search))
        try sendKey("a", code: 0, modifiers: .command, to: window)
        try sendKey("sacd 2", code: 1, to: window)
        await settle()
        let narrowed = try XCTUnwrap(table(in: content) as? FolderOutlineView)
        XCTAssertEqual(narrowed.numberOfRows, 1)
        XCTAssertEqual((narrowed.item(atRow: 0) as? FolderNode)?.url, matchingDisc)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        await settle()
        XCTAssertEqual(search.stringValue, "")
        let unfiltered = try XCTUnwrap(table(in: content) as? FolderOutlineView)
        XCTAssertEqual(unfiltered.numberOfRows, 1)
        XCTAssertEqual((unfiltered.item(atRow: 0) as? FolderNode)?.url, directory)
        XCTAssertTrue(window.firstResponder is NSTextView)
    }

    @MainActor
    func testTypingNarrowsManyFilteredRootsWithoutCrashingOrStealingFocus() async throws {
        for index in 0..<80 {
            try FileManager.default.createDirectory(
                at: directory.appendingPathComponent("Band \(index)/Disc"), withIntermediateDirectories: true
            )
        }
        let album = directory.appendingPathComponent("Brahms/Disc", isDirectory: true).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: album.appendingPathComponent("Disc"), withIntermediateDirectories: true
        )
        let state = AppState(metadataWriter: { _, _ in })
        state.rootURL = directory
        state.selectedFolder = directory
        let window = await host(SidebarView().environmentObject(state))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let search = try XCTUnwrap(textField(in: content))
        XCTAssertTrue(window.makeFirstResponder(search))
        try sendKey("b", code: 11, to: window)
        await settle()
        let broad = try XCTUnwrap(table(in: content) as? FolderOutlineView)
        XCTAssertEqual(broad.numberOfRows, 82)
        broad.expandItem(try XCTUnwrap(broad.item(atRow: 1)))
        await settle()
        XCTAssertTrue(window.makeFirstResponder(search))
        let broadEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        broadEditor.setSelectedRange(NSRange(location: broadEditor.string.utf16.count, length: 0))
        try sendKey("r", code: 15, to: window)
        await settle()
        XCTAssertEqual(search.stringValue, "br")
        let narrow = try XCTUnwrap(table(in: content) as? FolderOutlineView)
        XCTAssertEqual(narrow.numberOfRows, 1)
        XCTAssertEqual((narrow.item(atRow: 0) as? FolderNode)?.url, album)
        XCTAssertTrue(window.firstResponder is NSTextView)
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        editor.deleteBackward(nil)
        await settle()
        XCTAssertEqual(search.stringValue, "b")
        XCTAssertEqual(narrow.numberOfRows, 82)
        try sendKey("r", code: 15, to: window)
        await settle()
        XCTAssertEqual(narrow.numberOfRows, 1)
        XCTAssertTrue(window.firstResponder is NSTextView)
        try sendKey("zz", code: 6, to: window)
        await settle()
        XCTAssertNil(table(in: content))
        let emptyEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        emptyEditor.selectAll(nil)
        emptyEditor.deleteBackward(nil)
        await settle()
        let restored = try XCTUnwrap(table(in: content) as? FolderOutlineView)
        XCTAssertEqual(restored.numberOfRows, 1)
        XCTAssertEqual((restored.item(atRow: 0) as? FolderNode)?.url, directory)
        XCTAssertTrue(window.firstResponder is NSTextView)
    }

    @MainActor
    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 600, height: 500)) async -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        await settle()
        return window
    }

    @MainActor
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @MainActor
    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.table(in: $0) }.first
    }

    @MainActor
    private func tables(in view: NSView) -> [NSTableView] {
        if let table = view as? NSTableView { return [table] }
        return view.subviews.flatMap { tables(in: $0) }
    }

    @MainActor
    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { self.textField(in: $0) }.first
    }

    @MainActor
    private func button(in view: NSView) -> NSButton? {
        if let button = view as? NSButton { return button }
        return view.subviews.lazy.compactMap { self.button(in: $0) }.first
    }

    @MainActor
    private func sendKey(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                         to window: NSWindow, menu: NSMenu? = nil, repeating: Bool = false) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: (123...126).contains(code) ? modifiers.union([.numericPad, .function]) : modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: repeating, keyCode: code
        ))
        if menu?.performKeyEquivalent(with: event) == true { return }
        if !window.performKeyEquivalent(with: event) {
            window.sendEvent(event)
        }
    }

    @MainActor
    private func click(_ rect: NSRect, in view: NSView, window: NSWindow) throws {
        let point = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        // Drive native mouse tracking even when the XCTest app has no key window.
        NSApp.postEvent(up, atStart: true)
        view.mouseDown(with: down)
    }

    @MainActor
    private func dragColumnBoundary(_ column: Int, by distance: CGFloat, in table: NSTableView,
                                    window: NSWindow) throws {
        let header = try XCTUnwrap(table.headerView)
        let rect = header.headerRect(ofColumn: column)
        let start = header.convert(NSPoint(x: rect.maxX - 1, y: rect.midY), to: nil)
        let end = NSPoint(x: start.x + distance, y: start.y)
        let down = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown, location: start, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: end, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 1
        ))
        let up = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseUp, location: end, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 3, clickCount: 1, pressure: 0
        ))
        NSApp.postEvent(up, atStart: true)
        NSApp.postEvent(drag, atStart: true)
        header.mouseDown(with: down)
    }

    @MainActor
    func testFileTableDefaultsToTrackOrderAndKeyboardSelectionFollowsIt() async throws {
        let state = AppState(metadataWriter: { _, _ in })
        let ten = MediaFile(id: directory.appendingPathComponent("a.flac"))
        let two = MediaFile(id: directory.appendingPathComponent("b.flac"))
        let one = MediaFile(id: directory.appendingPathComponent("c.flac"))
        state.files = [ten, two, one]
        state.tracks = [ten.id: "10 / 12", two.id: "02 / 12", one.id: "01 / 12"]
        let window = await host(FileListView().environmentObject(state))
        defer { window.close() }
        let table = try XCTUnwrap(table(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(table))
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await settle()
        XCTAssertEqual(state.selectedFileIDs, [one.id])
        try sendKey("\u{f701}", code: 125, to: window)
        await settle()
        XCTAssertEqual(state.selectedFileIDs, [two.id])
        try sendKey("\u{f700}", code: 126, to: window)
        await settle()
        XCTAssertEqual(state.selectedFileIDs, [one.id])
        try sendKey("a", code: 0, modifiers: .command, to: window)
        await settle()
        XCTAssertEqual(state.selectedFileIDs, [one.id, two.id, ten.id])
    }

    @MainActor
    func testCommandAInTextFieldDoesNotSelectFiles() async throws {
        let state = AppState(metadataWriter: { _, _ in })
        let one = MediaFile(id: directory.appendingPathComponent("1.flac"))
        let two = MediaFile(id: directory.appendingPathComponent("2.flac"))
        state.files = [one, two]
        state.selectedFileIDs = [one.id]
        let text = "Editable metadata"
        let window = await host(
            VStack {
                FileListView().environmentObject(state)
                TextField("Title", text: .constant(text))
            }
        )
        defer { window.close() }
        let field = try XCTUnwrap(textField(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        // Hosted views have no app key window; route the standard Edit command
        // to this window's focused field editor instead.
        let editMenu = NSMenu(title: "Edit")
        let selectAll = NSMenuItem(
            title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        selectAll.target = editor
        editMenu.addItem(selectAll)
        try sendKey("a", code: 0, modifiers: .command, to: window)
        XCTAssertEqual(state.selectedFileIDs, [one.id])
        try sendKey("a", code: 0, modifiers: .command, to: window, menu: editMenu)
        await settle()
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: text.utf16.count))
        XCTAssertEqual(state.selectedFileIDs, [one.id])
    }

    @MainActor
    func testSidebarKeyboardExpansionAndVisibleRowSelection() async throws {
        let state = AppState(metadataWriter: { _, _ in })
        state.rootURL = directory
        state.selectedFolder = directory
        let window = await host(SidebarView().environmentObject(state))
        defer { window.close() }
        let table = try XCTUnwrap(table(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(table))
        XCTAssertEqual(table.numberOfRows, 1)
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        XCTAssertEqual(table.numberOfRows, 3)
        try sendKey("\u{f701}", code: 125, to: window)
        await settle()
        let a = directory.appendingPathComponent("a", isDirectory: true)
        XCTAssertEqual(state.selectedFolder, a)
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        XCTAssertEqual(table.numberOfRows, 4)
        try sendKey("\u{f702}", code: 123, to: window)
        await settle()
        XCTAssertEqual(table.numberOfRows, 3)
        try sendKey("\u{f702}", code: 123, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, directory)
        try sendKey("\u{f702}", code: 123, to: window)
        await settle()
        XCTAssertEqual(table.numberOfRows, 1)
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        try sendKey("\u{f701}", code: 125, to: window)
        await settle()
        try sendKey("\u{f700}", code: 126, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, directory)
    }

    @MainActor
    func testSidebarKeyboardNavigationInThreePaneWindowAndSearchFieldIsolation() async throws {
        let state = AppState(metadataWriter: { _, _ in })
        state.rootURL = directory
        state.selectedFolder = directory
        let window = await host(
            ContentView().environmentObject(state), size: NSSize(width: 1200, height: 800)
        )
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let sidebar = try XCTUnwrap(tables(in: content).first { $0.numberOfRows == 1 })
        let search = try XCTUnwrap(textField(in: content))
        XCTAssertTrue(window.makeFirstResponder(search))
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        XCTAssertEqual(sidebar.numberOfRows, 1)
        XCTAssertEqual(state.selectedFolder, directory)
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        XCTAssertEqual(sidebar.numberOfRows, 3)
        try sendKey("\u{f701}", code: 125, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, directory.appendingPathComponent("a", isDirectory: true))
        try sendKey("\u{f702}", code: 123, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, directory)
    }

    @MainActor
    func testSidebarAcceptsCapsLockAndRepeatedArrowsButLeavesShortcutsAlone() async throws {
        let state = AppState(metadataWriter: { _, _ in })
        state.rootURL = directory
        state.selectedFolder = directory
        let window = await host(SidebarView().environmentObject(state))
        defer { window.close() }
        let sidebar = try XCTUnwrap(table(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(window.makeFirstResponder(sidebar))
        try sendKey("\u{f703}", code: 124, modifiers: .command, to: window)
        await settle()
        XCTAssertEqual(sidebar.numberOfRows, 1)
        try sendKey("\u{f703}", code: 124, modifiers: .capsLock, to: window)
        await settle()
        XCTAssertEqual(sidebar.numberOfRows, 3)
        try sendKey("\u{f701}", code: 125, to: window, repeating: true)
        await settle()
        XCTAssertEqual(state.selectedFolder, directory.appendingPathComponent("a", isDirectory: true))
        try sendKey("\u{f701}", code: 125, to: window, repeating: true)
        await settle()
        XCTAssertEqual(state.selectedFolder, directory.appendingPathComponent("b", isDirectory: true))
    }

    @MainActor
    func testNativeTreeMouseClicksRestoreFocusAndKeepDisclosureSelectionVisible() async throws {
        let state = AppState(metadataWriter: { _, _ in })
        state.rootURL = directory
        state.selectedFolder = directory
        let window = await host(
            ContentView().environmentObject(state), size: NSSize(width: 1200, height: 800)
        )
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let outline = try XCTUnwrap(tables(in: content).compactMap { $0 as? FolderOutlineView }.first)
        let search = try XCTUnwrap(textField(in: content))
        XCTAssertTrue(window.makeFirstResponder(search))
        try click(outline.rect(ofRow: 0), in: outline, window: window)
        await settle()
        XCTAssertTrue(window.firstResponder === outline)
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        XCTAssertEqual(outline.numberOfRows, 3)
        try sendKey("\u{f701}", code: 125, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, directory.appendingPathComponent("a", isDirectory: true))
        let files = try XCTUnwrap(tables(in: content).first { !($0 is FolderOutlineView) })
        XCTAssertTrue(window.makeFirstResponder(files))
        try sendKey("\u{f701}", code: 125, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, directory.appendingPathComponent("a", isDirectory: true))
        try click(outline.rect(ofRow: 1), in: outline, window: window)
        await settle()
        XCTAssertTrue(window.firstResponder === outline)
        try sendKey("\u{f701}", code: 125, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, directory.appendingPathComponent("b", isDirectory: true))
        XCTAssertTrue(window.makeFirstResponder(search))
        let row = try XCTUnwrap(outline.rowView(atRow: 0, makeIfNecessary: true))
        let disclosure = try XCTUnwrap(button(in: row))
        disclosure.performClick(nil)
        await settle()
        XCTAssertTrue(window.firstResponder === outline)
        XCTAssertEqual(outline.numberOfRows, 1)
        XCTAssertEqual(state.selectedFolder, directory)
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        XCTAssertEqual(outline.numberOfRows, 3)
        try sendKey("\u{f701}", code: 125, to: window)
        await settle()
        XCTAssertEqual(state.selectedFolder, directory.appendingPathComponent("a", isDirectory: true))
    }

    @MainActor
    func testNativeTreeMenusRetainFolderActionsAndBatchDisabling() async throws {
        let state = AppState(metadataWriter: { _, _ in })
        state.rootURL = directory
        state.selectedFolder = directory
        let window = await host(SidebarView().environmentObject(state))
        defer { window.close() }
        let outline = try XCTUnwrap(table(in: XCTUnwrap(window.contentView)) as? FolderOutlineView)
        let menu = try XCTUnwrap(outline.folderMenu?(directory))
        XCTAssertEqual(menu.items.map(\.title), [
            "Reveal in Finder", "Reveal in Seeker", "",
            "Find Folders Without Cover…", "Auto-repair Covers in Subfolders…",
            "Normalize Embedded Covers in Subfolders…"
        ])
        XCTAssertTrue(menu.items[3].isEnabled)
        state.batchInProgress = true
        await settle()
        let busyMenu = try XCTUnwrap(outline.folderMenu?(directory))
        XCTAssertTrue(busyMenu.items[0].isEnabled)
        XCTAssertTrue(busyMenu.items[1].isEnabled)
        XCTAssertFalse(busyMenu.items[3].isEnabled)
        XCTAssertFalse(busyMenu.items[4].isEnabled)
        XCTAssertFalse(busyMenu.items[5].isEnabled)
    }

    @MainActor
    func testNativeTreeContextMenuActionStartsScanForRightClickedFolder() async throws {
        let musicFolder = directory.appendingPathComponent("a", isDirectory: true)
        let file = musicFolder.appendingPathComponent("song.mp3")
        try Data("FAKEMP3DATA".utf8).write(to: file)
        try ID3v2File.write(url: file, entries: [("TITLE", "Song")], cover: nil)
        let state = AppState(metadataWriter: { _, _ in })
        state.rootURL = directory
        state.selectedFolder = directory
        let window = await host(SidebarView().environmentObject(state))
        defer { window.close() }
        let outline = try XCTUnwrap(table(in: XCTUnwrap(window.contentView)) as? FolderOutlineView)
        outline.expandItem(try XCTUnwrap(outline.item(atRow: 0)))
        await settle()
        let rect = outline.rect(ofRow: 1)
        let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let menu = try XCTUnwrap(outline.menu(for: event))
        let item = try XCTUnwrap(menu.item(at: 3))
        let selector = try XCTUnwrap(item.action)
        XCTAssertEqual(NSStringFromSelector(selector), "invokeMenuItem:")
        guard NSStringFromSelector(selector) == "invokeMenuItem:" else { return }
        menu.performActionForItem(at: 3)
        XCTAssertTrue(state.batchInProgress)
        for _ in 0..<100 {
            if !state.batchInProgress { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(state.batchInProgress)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.coverlessScanRoot, musicFolder)
        XCTAssertEqual(state.coverlessFolders, [musicFolder])
    }

    @MainActor
    func testNativeFileContextMenuRefreshExecutesAndReloadsFiles() async throws {
        let state = AppState(metadataWriter: { _, _ in })
        state.selectedFolder = directory
        let stale = MediaFile(id: directory.appendingPathComponent("stale.mp3"))
        state.files = [stale]
        state.selectedFileIDs = [stale.id]
        let window = await host(FileListView().environmentObject(state))
        defer { window.close() }
        let file = MediaFile(id: directory.appendingPathComponent("new.mp3"))
        try Data("FAKEMP3DATA".utf8).write(to: file.url)
        try ID3v2File.write(url: file.url, entries: [("TITLE", "New")], cover: nil)
        let files = try XCTUnwrap(table(in: XCTUnwrap(window.contentView)) as? FileBrowserTableView)
        let menu = try XCTUnwrap(files.fileMenu?(0))
        XCTAssertEqual(menu.item(at: 3)?.title, "Refresh")
        let selector = try XCTUnwrap(menu.item(at: 3)?.action)
        XCTAssertEqual(NSStringFromSelector(selector), "invokeMenuItem:")
        guard NSStringFromSelector(selector) == "invokeMenuItem:" else { return }
        menu.performActionForItem(at: 3)
        XCTAssertEqual(state.files.map(\.id), [file.id])
        XCTAssertTrue(state.selectedFileIDs.isEmpty)
        XCTAssertNil(state.lastError)
    }

    @MainActor
    func testNativeTreeRefreshResetsExpansionWithoutStealingTextFocus() async throws {
        let fixture = NativeTreeFixture(root: root)
        let window = await host(NativeTreeFixtureView(fixture: fixture))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let outline = try XCTUnwrap(table(in: content) as? FolderOutlineView)
        XCTAssertTrue(window.makeFirstResponder(outline))
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        XCTAssertEqual(outline.numberOfRows, 3)
        let search = try XCTUnwrap(textField(in: content))
        XCTAssertTrue(window.makeFirstResponder(search))
        fixture.root = FolderNode(url: directory)
        await settle()
        XCTAssertEqual(outline.numberOfRows, 1)
        XCTAssertTrue(window.firstResponder is NSTextView)
        try click(outline.rect(ofRow: 0), in: outline, window: window)
        await settle()
        try sendKey("\u{f703}", code: 124, to: window)
        await settle()
        XCTAssertEqual(outline.numberOfRows, 3)
    }

    @MainActor
    func testClickingFilePanelAfterTreeTransfersFocusForArrowsAndCommandA() async throws {
        let state = AppState(metadataWriter: { _, _ in })
        state.rootURL = directory
        state.selectedFolder = directory
        let one = MediaFile(id: directory.appendingPathComponent("1.mp3"))
        let two = MediaFile(id: directory.appendingPathComponent("2.mp3"))
        let ten = MediaFile(id: directory.appendingPathComponent("10.mp3"))
        for file in [one, two, ten] {
            try Data("FAKEMP3DATA".utf8).write(to: file.url)
            try ID3v2File.write(url: file.url, entries: [("TITLE", file.name)], cover: nil)
        }
        state.files = [ten, two, one]
        let window = await host(
            ContentView().environmentObject(state), size: NSSize(width: 1200, height: 800)
        )
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let outline = try XCTUnwrap(tables(in: content).compactMap { $0 as? FolderOutlineView }.first)
        let files = try XCTUnwrap(tables(in: content).first { !($0 is FolderOutlineView) && $0.numberOfRows == 3 })
        try click(outline.rect(ofRow: 0), in: outline, window: window)
        await settle()
        XCTAssertTrue(window.firstResponder === outline)
        try click(files.rect(ofRow: 0), in: files, window: window)
        await settle()
        XCTAssertTrue(window.firstResponder === files)
        // AppKit's selection tracking needs an active app window; seed the
        // clicked row without changing the responder in this hosted test.
        files.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await settle()
        XCTAssertEqual(state.selectedFileIDs, [one.id])
        try sendKey("\u{f701}", code: 125, to: window)
        await settle()
        XCTAssertTrue(window.firstResponder === files)
        XCTAssertEqual(state.selectedFileIDs, [two.id])
        XCTAssertEqual(state.selectedFolder, directory)
        try sendKey("\u{f700}", code: 126, to: window)
        await settle()
        XCTAssertEqual(state.selectedFileIDs, [one.id])
        try sendKey("a", code: 0, modifiers: .command, to: window)
        await settle()
        XCTAssertEqual(state.selectedFileIDs, [one.id, two.id, ten.id])
        XCTAssertTrue(window.firstResponder === files)
        XCTAssertEqual(state.selectedFolder, directory)
        files.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await settle()
        try click(outline.rect(ofRow: 0), in: outline, window: window)
        await settle()
        XCTAssertTrue(window.firstResponder === outline)
        try sendKey("a", code: 0, modifiers: .command, to: window)
        await settle()
        XCTAssertEqual(state.selectedFileIDs, [one.id])
    }

    @MainActor
    func testNativeFileTablePreservesURLSelectionAcrossSortingAndMetadataUpdates() async throws {
        let one = FileListRow(file: MediaFile(id: directory.appendingPathComponent("1.mp3")),
                              title: "One", track: "01")
        let two = FileListRow(file: MediaFile(id: directory.appendingPathComponent("2.mp3")),
                              title: "Two", track: "02")
        let ten = FileListRow(file: MediaFile(id: directory.appendingPathComponent("10.mp3")),
                              title: "Ten", track: "10")
        let fixture = NativeFileFixture(rows: [one, two, ten], selection: [one.id])
        let window = await host(NativeFileFixtureView(fixture: fixture))
        defer { window.close() }
        let files = try XCTUnwrap(table(in: XCTUnwrap(window.contentView)) as? FileBrowserTableView)
        XCTAssertTrue(window.makeFirstResponder(files))
        fixture.rows = [ten, two, one]
        await settle()
        XCTAssertEqual(files.selectedRow, 2)
        XCTAssertEqual(fixture.selection, [one.id])
        try sendKey("\u{f700}", code: 126, to: window)
        await settle()
        XCTAssertEqual(fixture.selection, [two.id])
        fixture.rows[1] = FileListRow(file: two.file, title: "Edited", track: "02 / 12")
        await settle()
        XCTAssertTrue(window.firstResponder === files)
        XCTAssertEqual(fixture.selection, [two.id])
        let titleCell = try XCTUnwrap(files.view(atColumn: 2, row: 1, makeIfNecessary: true) as? NSTableCellView)
        let trackCell = try XCTUnwrap(files.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(titleCell.textField?.stringValue, "Edited")
        XCTAssertEqual(trackCell.textField?.stringValue, "02 / 12")
        try sendKey("a", code: 0, modifiers: [.command, .capsLock], to: window)
        await settle()
        XCTAssertEqual(fixture.selection, [one.id, two.id, ten.id])
        files.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        await settle()
        try sendKey("\u{f700}", code: 126, modifiers: .shift, to: window)
        await settle()
        XCTAssertEqual(fixture.selection, [ten.id, two.id])
    }

    @MainActor
    func testNativeFileContextMenuUsesClickedRowOrExistingMultiSelection() async throws {
        let one = FileListRow(file: MediaFile(id: directory.appendingPathComponent("1.mp3")),
                              title: nil, track: "")
        let two = FileListRow(file: MediaFile(id: directory.appendingPathComponent("2.mp3")),
                              title: nil, track: "")
        var targets: Set<URL> = []
        let fixture = NativeFileFixture(rows: [one, two], selection: [one.id])
        let window = await host(NativeFileTableView(
            rows: fixture.rows,
            selection: Binding(get: { fixture.selection }, set: { fixture.selection = $0 }),
            icon: { _ in "music.note" },
            menuEntries: { ids in targets = ids; return [] },
            onSortChanged: { _, _ in }
        ))
        defer { window.close() }
        let files = try XCTUnwrap(table(in: XCTUnwrap(window.contentView)) as? FileBrowserTableView)
        _ = files.fileMenu?(1)
        XCTAssertEqual(targets, [two.id])
        _ = files.fileMenu?(-1)
        XCTAssertEqual(targets, [one.id])
        fixture.selection = [one.id, two.id]
        _ = files.fileMenu?(0)
        XCTAssertEqual(targets, [one.id, two.id])
    }

    @MainActor
    func testNativeFileHeaderClickFocusDoesNotLetLaterUpdatesStealTextFocus() async throws {
        let row = FileListRow(file: MediaFile(id: directory.appendingPathComponent("1.mp3")),
                              title: "One", track: "01")
        let fixture = NativeFileFixture(rows: [row], selection: [row.id])
        let window = await host(NativeFileFixtureView(fixture: fixture))
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        let files = try XCTUnwrap(table(in: content))
        let field = try XCTUnwrap(textField(in: content))
        XCTAssertTrue(window.makeFirstResponder(field))
        let header = try XCTUnwrap(files.headerView as? FileBrowserHeaderView)
        try click(header.headerRect(ofColumn: 0), in: header, window: window)
        await settle()
        XCTAssertTrue(window.firstResponder === files)
        XCTAssertTrue(window.makeFirstResponder(field))
        fixture.rows[0] = FileListRow(file: row.file, title: "Updated", track: row.track)
        await settle()
        XCTAssertTrue(window.firstResponder is NSTextView)
    }

    @MainActor
    func testNativeColumnBoundaryDragResizesAndSurvivesMetadataUpdates() async throws {
        let row = FileListRow(file: MediaFile(id: directory.appendingPathComponent("1.mp3")),
                              title: "One", track: "01")
        let fixture = NativeFileFixture(rows: [row], selection: [row.id])
        let window = await host(NativeFileFixtureView(fixture: fixture))
        defer { window.close() }
        let files = try XCTUnwrap(table(in: XCTUnwrap(window.contentView)))
        XCTAssertTrue(files.allowsColumnResizing)
        XCTAssertFalse(files.allowsColumnReordering)
        XCTAssertTrue(files.tableColumns.allSatisfy { $0.resizingMask.contains(.userResizingMask) })
        let track = files.tableColumns[0]
        let originalWidth = track.width
        try dragColumnBoundary(0, by: 80, in: files, window: window)
        await settle()
        XCTAssertEqual(track.width, originalWidth + 80, accuracy: 2)
        XCTAssertGreaterThan(track.width, 90)
        XCTAssertEqual(files.sortDescriptors.first?.key, "track")
        XCTAssertEqual(files.sortDescriptors.first?.ascending, true)
        let resizedWidth = track.width
        fixture.rows[0] = FileListRow(file: row.file, title: "Updated", track: "01 / 12")
        await settle()
        XCTAssertEqual(track.width, resizedWidth, accuracy: 0.1)
        XCTAssertEqual(fixture.selection, [row.id])
        XCTAssertTrue(window.firstResponder === files)
    }

    @MainActor
    func testNativeHeaderSortsAllFieldsAndRetainsColumnWidthsAndSelection() async throws {
        let state = AppState(metadataWriter: { _, _ in })
        let a = MediaFile(id: directory.appendingPathComponent("a.mp3"))
        let b = MediaFile(id: directory.appendingPathComponent("b.mp3"))
        let c = MediaFile(id: directory.appendingPathComponent("c.mp3"))
        state.files = [a, b, c]
        state.tracks = [a.id: "10", b.id: "02 / 12", c.id: "01"]
        state.titles = [a.id: "Beta", b.id: "Gamma", c.id: "Alpha"]
        state.selectedFileIDs = [a.id]
        let window = await host(FileListView().environmentObject(state))
        defer { window.close() }
        let files = try XCTUnwrap(table(in: XCTUnwrap(window.contentView)))
        let header = try XCTUnwrap(files.headerView)
        XCTAssertEqual(files.tableColumns.map(\.title), ["#", "File", "Title"])
        XCTAssertEqual(files.selectedRow, 2)
        files.tableColumns[1].width = 180
        let width = files.tableColumns[1].width
        try click(header.headerRect(ofColumn: 1), in: header, window: window)
        await settle()
        XCTAssertEqual(files.sortDescriptors.first?.key, "file")
        XCTAssertEqual(files.sortDescriptors.first?.ascending, true)
        XCTAssertEqual(files.selectedRow, 0)
        try click(header.headerRect(ofColumn: 1), in: header, window: window)
        await settle()
        XCTAssertEqual(files.sortDescriptors.first?.ascending, false)
        XCTAssertEqual(files.selectedRow, 2)
        try click(header.headerRect(ofColumn: 2), in: header, window: window)
        await settle()
        XCTAssertEqual(files.sortDescriptors.first?.key, "title")
        XCTAssertEqual(files.sortDescriptors.first?.ascending, true)
        XCTAssertEqual(files.selectedRow, 1)
        try click(header.headerRect(ofColumn: 0), in: header, window: window)
        await settle()
        XCTAssertEqual(files.sortDescriptors.first?.key, "track")
        XCTAssertEqual(files.sortDescriptors.first?.ascending, true)
        XCTAssertEqual(files.selectedRow, 2)
        XCTAssertEqual(files.tableColumns[1].width, width, accuracy: 0.1)
        XCTAssertEqual(state.selectedFileIDs, [a.id])
        XCTAssertTrue(window.firstResponder === files)
    }
}

private final class NativeTreeFixture: ObservableObject {
    @Published var root: FolderNode
    @Published var selection: URL?

    init(root: FolderNode) {
        self.root = root
        selection = root.url
    }
}

private struct NativeTreeFixtureView: View {
    @ObservedObject var fixture: NativeTreeFixture

    var body: some View {
        VStack {
            TextField("Search", text: .constant(""))
            NativeFolderTreeView(root: fixture.root, selection: $fixture.selection, menuEntries: { _ in [] })
        }
    }
}

private final class NativeFileFixture: ObservableObject {
    @Published var rows: [FileListRow]
    @Published var selection: Set<URL>

    init(rows: [FileListRow], selection: Set<URL>) {
        self.rows = rows
        self.selection = selection
    }
}

private struct NativeFileFixtureView: View {
    @ObservedObject var fixture: NativeFileFixture

    var body: some View {
        VStack {
            TextField("Search", text: .constant(""))
            NativeFileTableView(rows: fixture.rows, selection: $fixture.selection,
                                icon: { _ in "music.note" }, menuEntries: { _ in [] },
                                onSortChanged: { _, _ in })
        }
    }
}
