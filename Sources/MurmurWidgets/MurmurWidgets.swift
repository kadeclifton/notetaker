// Murmur's desktop and Notification Center widget. It is a separate, sandboxed program that macOS
// runs on its own; scripts/build-app.sh packages it as Murmur.app/Contents/PlugIns/MurmurWidgets.appex.
// It only reads the numbers Murmur writes to the shared app group container (see WidgetSnapshot).
#if os(macOS) && canImport(WidgetKit)
import SwiftUI
import WidgetKit
import MurmurCore
import MurmurWidgetViews

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

#else
/// The widget is macOS only; this keeps `swift build` working elsewhere.
@main
enum MurmurWidgetsUnavailable {
    static func main() {}
}
#endif
