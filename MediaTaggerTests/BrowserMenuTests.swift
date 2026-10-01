import XCTest
import AppKit
@testable import MediaTagger

final class BrowserMenuTests: XCTestCase {
    @MainActor
    func testNativeMenuDispatchesItsClosureAction() throws {
        var calls = 0
        let menu = makeBrowserMenu([.item(title: "Run", enabled: true) { calls += 1 }])
        let item = try XCTUnwrap(menu.item(at: 0))
        let selector = try XCTUnwrap(item.action)
        XCTAssertEqual(NSStringFromSelector(selector), "invokeMenuItem:")
        guard NSStringFromSelector(selector) == "invokeMenuItem:" else { return }
        menu.performActionForItem(at: 0)
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testCopiedMenuRetainsItsActionTargetAndDispatches() throws {
        var calls = 0
        let menu: NSMenu = try autoreleasepool {
            let original = makeBrowserMenu([.item(title: "Run", enabled: true) { calls += 1 }])
            return try XCTUnwrap(original.copy() as? NSMenu)
        }
        let item = try XCTUnwrap(menu.item(at: 0))
        XCTAssertNotNil(item.target)
        let selector = try XCTUnwrap(item.action)
        XCTAssertEqual(NSStringFromSelector(selector), "invokeMenuItem:")
        guard NSStringFromSelector(selector) == "invokeMenuItem:" else { return }
        menu.performActionForItem(at: 0)
        XCTAssertEqual(calls, 1)
    }
}
