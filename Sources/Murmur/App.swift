#if os(macOS)
import AppKit

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
        controller.onChange = { [weak statusMenu] in statusMenu?.updateIcon() }
        self.controller = controller
        self.statusMenu = statusMenu
        controller.start()
    }
}
#endif
