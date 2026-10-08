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
    private var closing: NSObjectProtocol?
    /// Called once the window has closed.
    var onClose: (() -> Void)?
    /// In development, a file to save a picture of the window to; the app then quits.
    private let snapshot = ProcessInfo.processInfo.environment["AGENT_BOARD_SNAPSHOT"]

    init(model: BoardModel) {
        self.model = model
    }

    /// Whether the window is there to come back to: on screen, or minimised into the Dock.
    var isOpen: Bool { window.map { $0.isVisible || $0.isMiniaturized } ?? false }

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
        let window = snapshot == nil ? NSWindow(contentViewController: host) : UnseenWindow(contentViewController: host)
        // The pages name themselves and the window is drawn right up to its top edge, so the bar is empty
        // and clear. It is still there: with it the three buttons and the window's corners are where they
        // are in Finder or Mail, and without it they are those of a small utility window.
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbar = NSToolbar(identifier: "main")
        window.toolbarStyle = .unified
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Agent 状态牌"
        window.isReleasedWhenClosed = false  // closing it leaves the board running; it opens again from the Dock or the menu bar
        window.setContentSize(NSSize(width: 920, height: 660))
        window.center()
        window.setFrameAutosaveName("main")
        // In development, the picture can be taken in the dark appearance whatever the system is set to.
        if snapshot != nil, ProcessInfo.processInfo.environment["AGENT_BOARD_DARK"] != nil { window.appearance = NSAppearance(named: .darkAqua) }
        self.window = window
        // A page that comes up should not hand the keyboard to its first field: the window
        // scrolls to wherever the cursor is, and nobody asked to type yet.
        pageChanges = model.$page.sink { [weak window] _ in
            DispatchQueue.main.async { window?.makeFirstResponder(nil) }
        }
        closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.onClose?() }  // after it has gone, not as it is about to
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
