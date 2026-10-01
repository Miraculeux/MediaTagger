import AppKit

enum BrowserMenuEntry {
    case item(title: String, enabled: Bool, action: () -> Void)
    case separator
}

func makeBrowserMenu(_ entries: [BrowserMenuEntry]) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for entry in entries {
        switch entry {
        case .separator:
            menu.addItem(.separator())
        case .item(let title, let enabled, let action):
            let target = BrowserMenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(BrowserMenuAction.invokeMenuItem(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = target
            item.isEnabled = enabled
            menu.addItem(item)
        }
    }
    return menu
}

private final class BrowserMenuAction: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func invokeMenuItem(_ sender: NSMenuItem) { action() }
}
