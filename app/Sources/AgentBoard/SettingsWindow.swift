// The app's window: the settings pages the board serves on 127.0.0.1, shown in a
// window of the app's own instead of the browser.

import AppKit
import WebKit

final class SettingsWindow: NSObject, WKNavigationDelegate, WKUIDelegate {
    private let address: () -> String?  // the console's address, once it is listening
    private var window: NSWindow?
    private var web: WKWebView?
    /// In development, set to a file to save a picture of the page to; the app then quits.
    private let snapshot = ProcessInfo.processInfo.environment["AGENT_BOARD_SNAPSHOT"]

    init(address: @escaping () -> String?) {
        self.address = address
    }

    /// Bring the window forward, on the page named the way the pages' own links name it.
    func show(_ page: String = "") {
        guard let address = address(), let url = URL(string: "\(address)/#\(page)") else { return }
        if window == nil { build() }
        guard let window = window, let web = web else { return }
        if web.url?.port != url.port {
            web.load(URLRequest(url: url))
        } else if !page.isEmpty {
            web.evaluateJavaScript("location.hash = \"\(page)\"")
        }
        if snapshot != nil {
            window.setFrameOrigin(NSPoint(x: -20000, y: -20000))  // drawn, but not put in front of anyone
            window.orderFront(nil)
            return
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1040, height: 720), configuration: WKWebViewConfiguration())
        web.navigationDelegate = self
        web.uiDelegate = self
        let window = NSWindow(contentRect: web.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Agent 状态牌"
        window.contentView = web
        window.isReleasedWhenClosed = false  // closing it leaves the board running; it opens again from the Dock
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.setFrameAutosaveName("settings")
        self.web = web
        self.window = window
    }

    // Links that lead off the board, such as MindReset's documentation, belong in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.host != "127.0.0.1" || navigationAction.targetFrame == nil else {
            return decisionHandler(.allow)
        }
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    // The pages ask before restarting the board.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "好")
        alert.addButton(withTitle: "取消")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let path = snapshot else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {  // the page fills itself in after it loads
            webView.takeSnapshot(with: nil) { image, _ in
                if let tiff = image?.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                }
                exit(0)
            }
        }
    }
}
