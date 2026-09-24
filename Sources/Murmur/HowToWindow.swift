#if os(macOS)
import AppKit
import SwiftUI

/// A one-page cheat sheet: the three hotkey modes, hands-free, Esc, Compose styles and where things
/// are kept. Shown once when Murmur is first ready, and from Settings any time.
@MainActor
final class HowToWindowController {
    private var window: NSWindow?

    func show(hotkey: String, hasModes: Bool) {
        let view = HowToView(hotkey: hotkey, hasModes: hasModes) { [weak self] in self?.window?.close() }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "How to Use Murmur"
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window?.contentView = NSHostingView(rootView: view)
        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct HowToView: View {
    let hotkey: String
    let hasModes: Bool
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Talk anywhere you can type.").font(.title2.weight(.semibold))

            section("Hold a key, talk, let go") {
                row(hotkey, "Exactly what you said, as fast as possible.")
                if hasModes {
                    row(hotkey + "⌃", "Cleaned up: no \"um\"s, proper punctuation, your words.")
                    row(hotkey + "⌃⌥", "Compose: ramble it out, and it's written up in a preview. ⏎ inserts it.")
                    row(hotkey + "⇧", "Edit: select text, then say what to change (\"make it shorter\"). It's replaced.")
                }
            }

            section("More") {
                row("Double-tap \(hotkey)", "Hands-free: keep talking with nothing held. Tap \(hotkey) again to finish.")
                row("Esc", "Cancel a recording, or stop one that's still being transcribed.")
                row("⌃⌥V", "Paste your last dictation again, anywhere.")
                row("\"New line\"", "Say \"new line\" or \"new paragraph\" to break lines while you dictate.")
                row("\"Scratch that\"", "Say it on its own to undo the last dictation; end a sentence with it to drop that one.")
                row("Snippets", "Say a phrase like \"my email\" and saved text goes in instead. Set them in Settings.")
                if hasModes {
                    row("\"…as bullet points\"", "Tell Compose the form you want: an email, a message, bullets, a prompt.")
                }
            }

            section("Where things are") {
                row("Menu bar wave", "Recent dictations, the Library (Compose pieces and meetings), Meeting Notes, Settings.")
                row("Settings… ⌘,", "Hotkey, microphone, speech model, Neural Engine, vocabulary, snippets, meetings.")
            }

            Spacer(minLength: 0)
            HStack {
                Text("Open this again from the menu: More → How to Use Murmur.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Got It", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func row(_ keys: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(keys)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.purple.opacity(0.12)))
                .frame(minWidth: 130, alignment: .leading)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}
#endif
