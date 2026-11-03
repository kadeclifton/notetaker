#if os(macOS)
import AppKit
import MurmurCore

@main
enum MurmurApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        // `Murmur --snapshots <folder>`: the screenshot tests, instead of the app (see Snapshots).
        if let folder = Snapshots.folder() {
            let delegate = SnapshotDelegate(folder: folder)
            app.delegate = delegate
            app.setActivationPolicy(.regular)
            withExtendedLifetime(delegate) { app.run() }
            return
        }
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon, never steals focus from the app you are typing in.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}

/// Runs the screenshot tests, then quits with their result.
@MainActor
final class SnapshotDelegate: NSObject, NSApplicationDelegate {
    let folder: URL

    init(folder: URL) {
        self.folder = folder
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A window that never finishes appearing must not hang CI.
        DispatchQueue.main.asyncAfter(deadline: .now() + 240) {
            print("Screenshots timed out.")
            exit(3)
        }
        Task { @MainActor in
            let status = await Snapshots.run(into: self.folder)
            exit(status)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: DictationController?
    private var statusMenu: StatusMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = DictationController()
        let statusMenu = StatusMenu(controller: controller)
        controller.onChange = { [weak statusMenu, weak controller] in
            statusMenu?.updateIcon()
            controller?.settingsWindow.refresh()
        }
        self.controller = controller
        self.statusMenu = statusMenu
        controller.start()
    }

    /// murmur:// links from the desktop widget.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { controller?.open(url) }
    }

    /// Quitting mid-meeting saves the transcript first (without waiting for a summary).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let controller, controller.meeting != nil else { return .terminateNow }
        controller.stopMeeting(summarize: false) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        // whisper-server is a separate process; do not leave it running.
        WhisperServer.stopShared()
    }
}
#endif
