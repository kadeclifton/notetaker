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
    }

    static func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Launch at login through SMAppService (macOS 13+). Needs the app to be a real .app bundle.
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
