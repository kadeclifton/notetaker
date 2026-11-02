// Murmur's desktop and Notification Center widget. It is a separate, sandboxed program that macOS
// runs on its own; scripts/build-app.sh packages it as Murmur.app/Contents/PlugIns/MurmurWidgets.appex.
// It only reads the numbers Murmur writes to the shared app group container (see WidgetSnapshot).
#if os(macOS) && canImport(WidgetKit)
import AppKit
import SwiftUI
import WidgetKit
import MurmurCore

@main
struct MurmurWidgetBundle: WidgetBundle {
    var body: some Widget {
        TodayWidget()
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MurmurToday", provider: Provider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName("Murmur")
        .description("Words you've dictated today, your week, and your latest meeting notes.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct MurmurEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    /// False until Murmur has written numbers the widget can read.
    let isReady: Bool
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> MurmurEntry {
        MurmurEntry(date: Date(), snapshot: .sample(), isReady: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (MurmurEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entry(at: Date()))
    }

    /// Now, and again at midnight, when today starts over even if Murmur writes nothing new.
    func getTimeline(in context: Context, completion: @escaping (Timeline<MurmurEntry>) -> Void) {
        let now = Date()
        let midnight = Calendar.current.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0),
                                                 matchingPolicy: .nextTime) ?? now.addingTimeInterval(3600)
        completion(Timeline(entries: [entry(at: now), entry(at: midnight)], policy: .after(midnight)))
    }

    private func entry(at date: Date) -> MurmurEntry {
        guard let snapshot = Self.load() else { return MurmurEntry(date: date, snapshot: .sample(now: date), isReady: false) }
        return MurmurEntry(date: date, snapshot: snapshot.rolledOver(to: date), isReady: true)
    }

    static func load() -> WidgetSnapshot? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: WidgetSnapshot.appGroupKey) as? String, !group.isEmpty,
              let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group),
              let data = try? Data(contentsOf: folder.appendingPathComponent(WidgetSnapshot.fileName)) else { return nil }
        return try? WidgetSnapshot.decode(data)
    }
}

// MARK: - Views

struct TodayWidgetView: View {
    let entry: MurmurEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        Group {
            if !entry.isReady {
                NotReady()
            } else if family == .systemMedium {
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
        .containerBackground(for: .widget) {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [Color.purple.opacity(0.16), Color.purple.opacity(0.02)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
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
                                .fill(index == week.count - 1 ? AnyShapeStyle(Color.purple.gradient) : AnyShapeStyle(.quaternary))
                                .frame(height: max(3, geometry.size.height * CGFloat(day.words) / CGFloat(most)))
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
}

/// Murmur's 13 bars.
private struct BrandMark: View {
    var body: some View {
        GeometryReader { geometry in
            let count = Brand.barHeights.count
            let bar = geometry.size.width / CGFloat(count * 2 - 1)
            HStack(alignment: .center, spacing: bar) {
                ForEach(Brand.barHeights.indices, id: \.self) { index in
                    Capsule()
                        .frame(width: bar, height: max(bar, geometry.size.height * CGFloat(Brand.barHeights[index])))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .foregroundStyle(Color.purple.gradient)
        .widgetAccentable()
        .accessibilityHidden(true)
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
#else
/// The widget is macOS only; this keeps `swift build` working elsewhere.
@main
enum MurmurWidgetsUnavailable {
    static func main() {}
}
#endif
