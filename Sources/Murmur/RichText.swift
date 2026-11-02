#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// Markdown shown as a document: headings, bullets, check boxes, quotes, and meeting transcript lines
/// as chat bubbles. Bold, italics and links inside the text are rendered too.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                Self.row(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    static func row(_ block: MarkdownBlock) -> some View {
        switch block {
        case let .heading(level, text):
            Text(inline(text))
                .font(level == 1 ? .title.weight(.bold) : level == 2 ? .title2.weight(.semibold) : .headline)
                .padding(.top, level <= 2 ? 10 : 6)
        case let .bullet(text, indent):
            ListItemRow(indent: indent, marker: Text("•").foregroundStyle(.secondary)) { Text(inline(text)) }
        case let .task(text, done, indent):
            ListItemRow(indent: indent, marker: Text(Image(systemName: done ? "checkmark.circle.fill" : "circle"))
                .foregroundStyle(done ? Color.green : Color.secondary)) {
                Text(inline(text)).strikethrough(done).foregroundStyle(done ? .secondary : .primary)
            }
        case let .numbered(marker, text, indent):
            ListItemRow(indent: indent, marker: Text(marker).monospacedDigit().foregroundStyle(.secondary)) { Text(inline(text)) }
        case let .quote(text):
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5).fill(.tertiary).frame(width: 3)
                Text(inline(text)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 4)
        case let .paragraph(text):
            Text(inline(text))
        case let .turn(time, speaker, text):
            TranscriptBubble(speaker: speaker, time: time, text: text)
        }
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A bullet, check box or number, with its text wrapping under itself rather than under the marker.
private struct ListItemRow<Content: View>: View {
    let indent: Int
    let marker: Text
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            marker.frame(minWidth: 14, alignment: .trailing)
            content.fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(indent) * 20)
    }
}

/// One turn of a meeting, as in Messages: your words on the right in purple, everyone else's on the left.
struct TranscriptBubble: View {
    let speaker: String
    let time: String
    let text: String

    private var isMe: Bool { speaker == Speaker.me.rawValue }

    var body: some View {
        VStack(alignment: isMe ? .trailing : .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(speaker).fontWeight(.semibold)
                Text(time).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            Text(MarkdownView.inline(text))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(bubble.fill(isMe ? AnyShapeStyle(Color.purple.opacity(0.16)) : AnyShapeStyle(.quinary)))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560, alignment: isMe ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: isMe ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }

    /// Rounded, with a sharper corner on the speaker's side, like a chat bubble's tail.
    private var bubble: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: isMe ? 14 : 4,
                               bottomTrailingRadius: isMe ? 4 : 14, topTrailingRadius: 14, style: .continuous)
    }
}

/// Three dots that rise in turn while the next piece is transcribed. Still with Reduce Motion.
struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let time: TimeInterval = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    let wave: Double = Self.wave(index: index, time: time)
                    Circle()
                        .frame(width: 7, height: 7)
                        .opacity(0.35 + 0.65 * wave)
                        .offset(y: CGFloat(-2 * wave))
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Capsule().fill(.quinary))
        }
        .accessibilityLabel("Transcribing")
    }

    /// 0...1 for dot `index`: each rises a little after the one before it.
    static func wave(index: Int, time: TimeInterval) -> Double {
        let phase: Double = time * 1.4 - Double(index) * 0.2
        return 0.5 + 0.5 * sin(2 * Double.pi * phase)
    }
}

/// A Compose style as a small colored tag.
struct StyleChip: View {
    let style: ComposeStyle

    static func color(_ style: ComposeStyle) -> Color {
        switch style {
        case .auto: return .gray
        case .message: return .green
        case .email: return .blue
        case .bullets: return .orange
        case .document: return .indigo
        case .prompt: return .purple
        }
    }

    var body: some View {
        Text(style.title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Self.color(style))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Self.color(style).opacity(0.15)))
    }
}

/// The system search field (magnifying glass, clear button), for a sidebar.
struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt = "Search"

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = prompt
        field.delegate = context.coordinator
        // The clear button reports through the action, not as a text change.
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @objc func changed(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }
    }
}

/// A key name drawn like the key: "fn", "esc", "fn⌃".
struct KeyCap: View {
    let name: String
    init(_ name: String) { self.name = name }

    var body: some View {
        Text(name)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.quaternary))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.tertiary, lineWidth: 0.5))
    }
}

/// A rounded card on the window's background, for the meeting summary and similar groups.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quinary))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.quaternary, lineWidth: 0.5))
    }
}
#endif
