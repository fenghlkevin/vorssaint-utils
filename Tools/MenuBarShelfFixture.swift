// SPDX-License-Identifier: GPL-3.0-or-later
// Manual integration fixture: a real status item with a harmless menu.
import AppKit

final class ShelfFixtureDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var item: NSStatusItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.set(800, forKey: "NSStatusItem Preferred Position ShelfClickTest")
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.autosaveName = "ShelfClickTest"
        item.button?.image = NSImage(systemSymbolName: "checkmark.seal", accessibilityDescription: "Shelf Click Test")
        item.button?.toolTip = "Shelf Click Test"
        let menu = NSMenu(title: "Shelf Click Test")
        menu.delegate = self
        menu.addItem(withTitle: "面板点击联动验证成功", action: nil, keyEquivalent: "")
        menu.addItem(withTitle: "退出测试", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        self.item = item
        print("SHELF_FIXTURE_READY bundle=\(Bundle.main.bundleIdentifier ?? "none")")
        fflush(stdout)
    }
    func menuWillOpen(_ menu: NSMenu) {
        print("SHELF_FIXTURE_MENU_OPEN")
        fflush(stdout)
    }
    func menuDidClose(_ menu: NSMenu) {
        print("SHELF_FIXTURE_MENU_CLOSED")
        fflush(stdout)
    }
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = ShelfFixtureDelegate()
app.delegate = delegate
app.run()
