import AppKit

@main
struct SupersetApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: MainWindowController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Open database — fail fast if missing
        let dbPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".superset/local.db").path

        guard let db = DatabaseManager(path: dbPath) else {
            let alert = NSAlert()
            alert.messageText = "Database Not Found"
            alert.informativeText = "Could not open \(dbPath). Please run Superset desktop at least once to initialize the database."
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        DatabaseManager.shared = db

        windowController = MainWindowController(db: db)
        windowController.loadWebContent()
        windowController.window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        PTYSessionManager.shared.destroyAll()
    }
}
