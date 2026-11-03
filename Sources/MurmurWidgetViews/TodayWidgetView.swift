// The desktop widget's views, shared by the widget extension (MurmurWidgets) and the app, whose
// screenshot tests (`Murmur --snapshots`) draw them in every size.
#if os(macOS) && canImport(WidgetKit)
import AppKit
import SwiftUI
import WidgetKit
import MurmurCore

// MARK: - Views

public struct MurmurEntry: TimelineEntry {
    public let date: Date
    public let snapshot: WidgetSnapshot
    /// False until Murmur has written numbers the widget can read.
    public let isReady: Bool

    public init(date: Date, snapshot: WidgetSnapshot, isReady: Bool) {
        self.date = date
        self.snapshot = snapshot
        self.isReady = isReady
    }
}

public struct TodayWidgetView: View {
    let entry: MurmurEntry
    /// Nil inside the widget, which reads its size from the environment; the screenshot tests,
    /// which draw it outside one, say which size.
    let size: WidgetFamily?
    @Environment(\.widgetFamily) private var environmentFamily

    public init(entry: MurmurEntry, size: WidgetFamily? = nil) {
        self.entry = entry
        self.size = size
    }

    private var snapshot: WidgetSnapshot { entry.snapshot }

    public var body: some View {
        Group {
            if !entry.isReady {
                NotReady()
            } else if (size ?? environmentFamily) == .systemMedium {
                HStack(spacing: 14) {
                    TodayPanel(snapshot: snapshot, showsDays: true)
                    Divider()
                    MeetingPanel(snapshot: snapshot)
                }
            } else {
                TodayPanel(snapshot: snapshot, showsDays: false)
            }
        }
        .widgetURL((snapshot.meetingStarted == nil ? MurmurLink.library(meetings: false) : .meeting).url)
        .containerBackground(for: .widget) { WidgetBackground() }
    }
}

/// The widget's background: the window color with a faint wash of Murmur's purple.
public struct WidgetBackground: View {
    public init() {}

    public var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            LinearGradient(colors: [Color.purple.opacity(0.16), Color.purple.opacity(0.02)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

/// Today's words, the time they saved, and the week as bars.
private struct TodayPanel: View {
    let snapshot: WidgetSnapshot
    let showsDays: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                BrandMark().frame(width: 25, height: 11)
                Text("Today").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let started = snapshot.meetingStarted, !showsDays {
                Label("Recording", systemImage: "record.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text(started, style: .timer)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("meeting notes").font(.caption).foregroundStyle(.secondary)
            } else {
                Text(snapshot.wordsToday.formatted())
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText(value: Double(snapshot.wordsToday)))
                    .widgetAccentable()
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            WeekBars(week: snapshot.week, showsDays: showsDays)
                .frame(height: showsDays ? 34 : 22)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var subtitle: String {
        guard snapshot.wordsToday > 0 else { return "Hold \(snapshot.hotkey) to talk" }
        let minutes = Int(snapshot.minutesSavedToday.rounded())
        return minutes > 0 ? "words · \(minutes) min saved" : (snapshot.wordsToday == 1 ? "word dictated" : "words dictated")
    }
}

/// The meeting being recorded with a Stop button, or the last one's highlights with Start.
private struct MeetingPanel: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let started = snapshot.meetingStarted {
                Label("Recording", systemImage: "record.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text(started, style: .timer)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Notes and a summary are written when you stop.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                PillLink(title: "Stop & Summarize", systemImage: "stop.fill", tint: .red, link: .stopMeeting)
            } else if let meeting = snapshot.lastMeeting {
                Text("Last meeting").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(meeting.title).font(.headline).lineLimit(1)
                Text(meeting.date, format: .relative(presentation: .named))
                    .font(.caption2).foregroundStyle(.secondary)
                ForEach(meeting.highlights.prefix(2), id: \.self) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("•").foregroundStyle(.secondary)
                        Text(line).lineLimit(1)
                    }
                    .font(.caption)
                }
                Spacer(minLength: 4)
                HStack {
                    if meeting.openActionItems > 0 {
                        Label("\(meeting.openActionItems)", systemImage: "checklist")
                            .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    PillLink(title: "Start Notes", systemImage: "record.circle", tint: .purple, link: .startMeeting)
                }
            } else {
                Text("Meeting Notes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text("Transcribe a call and get a summary with action items.")
                    .font(.caption).lineLimit(3)
                Spacer(minLength: 4)
                PillLink(title: "Start Notes", systemImage: "record.circle", tint: .purple, link: .startMeeting)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A capsule button that opens Murmur at `url`.
private struct PillLink: View {
    let title: String
    let systemImage: String
    let tint: Color
    let link: MurmurLink

    var body: some View {
        Link(destination: link.url) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(tint.opacity(0.18)))
                .foregroundStyle(tint)
                .widgetAccentable()
        }
    }
}

/// The last seven days as bars, today's in color.
private struct WeekBars: View {
    let week: [WidgetSnapshot.Day]
    let showsDays: Bool

    var body: some View {
        let most = max(1, week.map(\.words).max() ?? 1)
        HStack(alignment: .bottom, spacing: showsDays ? 5 : 3) {
            ForEach(Array(week.enumerated()), id: \.offset) { index, day in
                VStack(spacing: 2) {
                    GeometryReader { geometry in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(Self.style(isToday: index == week.count - 1))
                                .frame(height: Self.height(words: day.words, most: most, room: geometry.size.height))
                        }
                    }
                    if showsDays {
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .widgetAccentable(index == week.count - 1)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(week.reduce(0) { $0 + $1.words }) words this week")
    }

    static func style(isToday: Bool) -> AnyShapeStyle {
        isToday ? AnyShapeStyle(Color.purple.gradient) : AnyShapeStyle(.quaternary)
    }

    static func height(words: Int, most: Int, room: CGFloat) -> CGFloat {
        let share = CGFloat(words) / CGFloat(max(1, most))
        return max(3, room * share)
    }
}

/// Murmur's 13 bars.
private struct BrandMark: View {
    var body: some View {
        GeometryReader { geometry in
            let count: Int = Brand.barHeights.count
            let bar: CGFloat = geometry.size.width / CGFloat(count * 2 - 1)
            HStack(alignment: .center, spacing: bar) {
                ForEach(Brand.barHeights.indices, id: \.self) { index in
                    Capsule()
                        .frame(width: bar, height: Self.height(index: index, bar: bar, room: geometry.size.height))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(Color.purple.gradient)
        .widgetAccentable()
        .accessibilityHidden(true)
    }

    static func height(index: Int, bar: CGFloat, room: CGFloat) -> CGFloat {
        max(bar, room * CGFloat(Brand.barHeights[index]))
    }
}

private struct NotReady: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BrandMark().frame(width: 34, height: 15)
            Text("Murmur").font(.headline)
            Text("Open Murmur once, and your dictation and meetings show up here.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}
#endif
