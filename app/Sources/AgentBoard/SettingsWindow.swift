// The app's window. SwiftUI draws what is in it; this decides when it is on screen.

import AppKit
import Combine
import SwiftUI

/// A window for taking a picture of in development. macOS pulls an ordinary window
/// back onto a screen when it is placed off all of them; this one stays where it is put.
private final class UnseenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class SettingsWindow {
    private let model: BoardModel
    private var window: NSWindow?
    private var pageChanges: AnyCancellable?
    /// In development, a file to save a picture of the window to; the app then quits.
    private let snapshot = ProcessInfo.processInfo.environment["AGENT_BOARD_SNAPSHOT"]

    init(model: BoardModel) {
        self.model = model
    }

    /// Bring the window forward, on `page` when one is asked for.
    func show(_ page: Page? = nil) {
        if let page = page { model.page = page }
        model.refresh()
        if window == nil { build() }
        guard let window = window else { return }
        if let path = snapshot {
            // Laid out and drawn into a picture, but never seen: invisible, far off every screen, and deaf to the mouse and keyboard.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
            window.orderBack(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.save(window, to: path) }
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let host = NSHostingController(rootView: RootView(model: model))
        host.sceneBridgingOptions = [.toolbars, .title]  // the sidebar and the page title go into the window's own bar
        let window = snapshot == nil ? NSWindow(contentViewController: host) : UnseenWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Agent 状态牌"
        window.isReleasedWhenClosed = false  // closing it leaves the board running; it opens again from the Dock
        window.setContentSize(NSSize(width: 920, height: 660))
        window.center()
        window.setFrameAutosaveName("main")
        self.window = window
        // A page that comes up should not hand the keyboard to its first field: the window
        // scrolls to wherever the cursor is, and nobody asked to type yet.
        pageChanges = model.$page.sink { [weak window] _ in
            DispatchQueue.main.async { window?.makeFirstResponder(nil) }
        }
    }

    private func save(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView, let picture = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            exit(1)
        }
        view.cacheDisplay(in: view.bounds, to: picture)
        try? picture.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        exit(0)
    }
}
