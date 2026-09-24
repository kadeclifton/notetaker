#if os(macOS)
import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

/// The three privacy permissions Murmur needs, and shortcuts to the right Settings pane.
enum Permissions {
    /// Posting Cmd-V / keystrokes into other apps, and swallowing a shortcut hotkey.
    static var accessibility: Bool { AXIsProcessTrusted() }

    /// Seeing key presses from other apps (the hotkey and Esc).
    static var inputMonitoring: Bool { CGPreflightListenEventAccess() }

    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }


    /// Shows the system prompt that adds Murmur to the Accessibility list.
    static func promptAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
    }

    static func requestMicrophone(completion: @escaping @Sendable (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
    }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
        case microphone = "Privacy_Microphone"
        case screenRecording = "Privacy_ScreenCapture"
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Launch at login through SMAppService (macOS 13+). Needs the app to be a real .app bundle.
extension Permissions {
    @MainActor private static var reopenWatch: Process?

    /// Some permissions (Input Monitoring, Screen Recording) make macOS quit Murmur, and its
    /// "Reopen" does not always bring a menu bar app back. A small shell loop waits for this process
    /// to end and opens Murmur again if nothing else did. It gives up after 15 minutes, and a Quit
    /// from Murmur's own menu cancels it.
    @MainActor
    static func reopenIfQuit() {
        guard reopenWatch?.isRunning != true else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let pid = ProcessInfo.processInfo.processIdentifier
        process.arguments = ["-c", """
            end=$((SECONDS + 900))
            while kill -0 \(pid) 2>/dev/null; do
              [ $SECONDS -gt $end ] && exit 0
              sleep 0.5
            done
            sleep 2
            pgrep -xq Murmur || /usr/bin/open "$0"
            """, Bundle.main.bundleURL.path]
        try? process.run()
        reopenWatch = process
    }

    /// Quitting on purpose: don't bring Murmur back.
    @MainActor
    static func cancelReopen() {
        reopenWatch?.terminate()
        reopenWatch = nil
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
#endif
