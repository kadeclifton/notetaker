#if os(macOS)
import AppKit
import MurmurCore

@main
enum MurmurApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Menu bar only: no Dock icon, never steals focus from the app you are typing in.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
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
