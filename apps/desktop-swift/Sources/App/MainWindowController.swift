import AppKit
import SwiftUI
import WebKit
import os

final class MainWindowController: NSObject, WKNavigationDelegate {

    let window: NSWindow
    private(set) var webView: WKWebView!
    private let schemeHandler = SupersetSchemeHandler()
    private var controlHandler: ControlMessageHandler!
    private let sessionManager = PTYSessionManager.shared
    private let db: DatabaseManager
    let sidebarViewModel: SidebarViewModel
    private let logger = Logger(subsystem: "sh.superset.shell", category: "Window")

    init(db: DatabaseManager) {
        self.db = db
        self.sidebarViewModel = SidebarViewModel(db: db)

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Superset"
        window.center()
        window.setFrameAutosaveName("SupersetMainWindow")
        window.minSize = NSSize(width: 640, height: 480)

        setupSplitView()
        wireViewModel()
        sidebarViewModel.startObserving()
    }

    private func setupSplitView() {
        // Create WKWebView
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(schemeHandler, forURLScheme: "superset")

        controlHandler = ControlMessageHandler(schemeHandler: schemeHandler, windowController: self)
        config.userContentController.add(controlHandler, name: "superset")

        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        #endif

        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self

        // Create NSSplitViewController
        let splitVC = NSSplitViewController()

        // Sidebar (SwiftUI)
        let sidebarView = SidebarView(viewModel: sidebarViewModel)
        let sidebarHosting = NSHostingController(rootView: sidebarView)
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHosting)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 350
        sidebarItem.canCollapse = true

        // Terminal (WKWebView)
        let terminalVC = NSViewController()
        terminalVC.view = webView
        let terminalItem = NSSplitViewItem(contentListWithViewController: terminalVC)

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(terminalItem)

        window.contentViewController = splitVC
    }

    private func wireViewModel() {
        sidebarViewModel.onCreateAndShowTerminal = { [weak self] sessionId, cwd in
            self?.createAndShowTerminal(sessionId: sessionId, cwd: cwd)
        }
        sidebarViewModel.onShowTerminal = { [weak self] sessionId in
            self?.switchTerminal(sessionId: sessionId)
        }
        sidebarViewModel.onDestroyTerminal = { [weak self] sessionId in
            self?.destroyTerminal(sessionId: sessionId)
        }
    }

    func loadWebContent() {
        guard let resourceURL = Bundle.main.url(
            forResource: "index",
            withExtension: "html",
            subdirectory: "WebContent"
        ) else {
            logger.fault("WebContent/index.html not found in app bundle")
            return
        }

        let directoryURL = resourceURL.deletingLastPathComponent()
        webView.loadFileURL(resourceURL, allowingReadAccessTo: directoryURL)
    }

    // MARK: - Terminal Operations

    func createAndShowTerminal(sessionId: String, cwd: String) {
        do {
            try sessionManager.createSession(
                sessionId: sessionId,
                cwd: cwd,
                onBatchReady: { [weak self] id, data in
                    DispatchQueue.main.async {
                        self?.schemeHandler.sendBatch(sessionId: id, data: data)
                    }
                },
                onExit: { [weak self] id, code, signal in
                    DispatchQueue.main.async {
                        self?.schemeHandler.finishStream(sessionId: id, exitCode: code, signal: signal)
                    }
                }
            )
        } catch {
            logger.error("Failed to create PTY session: \(error.localizedDescription)")
            return
        }

        let escaped = sessionId.jsEscaped
        webView.evaluateJavaScript("window.__superset?.initTerminal('\(escaped)')")
        webView.evaluateJavaScript("window.__superset?.showTerminal('\(escaped)')")
    }

    func switchTerminal(sessionId: String) {
        let escaped = sessionId.jsEscaped
        webView.evaluateJavaScript("window.__superset?.showTerminal('\(escaped)')")
    }

    func destroyTerminal(sessionId: String) {
        let escaped = sessionId.jsEscaped
        webView.evaluateJavaScript("window.__superset?.destroyTerminal('\(escaped)')")
    }

    // MARK: - WKNavigationDelegate

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        logger.warning("WebContent process terminated — reloading")
        schemeHandler.invalidateAllStreams()
        webView.reload()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        logger.info("WebView navigation finished")
    }

    /// Called by ControlMessageHandler when JS sends { action: "ready" }.
    func handleJSReady() {
        // Reconnect existing PTY sessions (WebView crash recovery)
        let existingIds = sessionManager.activeSessionIds()
        if !existingIds.isEmpty {
            logger.info("JS ready — reconnecting \(existingIds.count) existing PTY session(s)")
            for sessionId in existingIds {
                let escaped = sessionId.jsEscaped
                webView.evaluateJavaScript("window.__superset?.initTerminal('\(escaped)')")
            }
        }

        // Create PTY for active workspace (app launch — lazy)
        if let activeId = sidebarViewModel.activeWorkspaceId {
            if sessionManager.session(for: activeId) != nil {
                // Already reconnected above, just show
                switchTerminal(sessionId: activeId)
            } else {
                // Fresh launch — create PTY for active workspace
                if let ws = try? db.workspace(id: activeId) {
                    let cwd = (try? db.workspaceCwd(workspace: ws))
                        ?? FileManager.default.homeDirectoryForCurrentUser.path
                    createAndShowTerminal(sessionId: activeId, cwd: cwd)
                }
            }
        } else {
            logger.info("JS ready — no active workspace")
        }
    }
}

extension String {
    var jsEscaped: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
