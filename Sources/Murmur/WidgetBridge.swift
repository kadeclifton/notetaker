#if os(macOS)
import Foundation
import WidgetKit
import MurmurCore

/// Keeps the desktop widget current: writes a `WidgetSnapshot` to the app group container the widget
/// reads, and asks WidgetKit to redraw. Sparingly, since macOS caps how often a widget reloads:
/// meetings starting or stopping redraw at once, dictation stats at most every few minutes.
@MainActor
final class WidgetBridge {
    static let reloadInterval: TimeInterval = 5 * 60
    private var lastReload: Date?
    private var pendingReload: Task<Void, Never>?
    private var lastWritten: WidgetSnapshot?

    /// Nil in builds not signed with a Developer ID, which have no app group; the widget then asks
    /// you to open Murmur.
    private static let fileURL: URL? = {
        guard let group = Bundle.main.object(forInfoDictionaryKey: WidgetSnapshot.appGroupKey) as? String, !group.isEmpty,
              let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return folder.appendingPathComponent(WidgetSnapshot.fileName)
    }()

    var isAvailable: Bool { Self.fileURL != nil }

    func publish(_ snapshot: WidgetSnapshot, urgent: Bool) {
        guard let url = Self.fileURL else { return }
        var unchanged = snapshot
        unchanged.updated = lastWritten?.updated ?? snapshot.updated
        guard unchanged != lastWritten || urgent else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try snapshot.encoded().write(to: url, options: .atomic)
            lastWritten = snapshot
        } catch {
            NSLog("Murmur: could not update the widget: %@", "\(error)")
            return
        }
        let now = Date()
        let wait = urgent ? 0 : max(0, (lastReload?.addingTimeInterval(Self.reloadInterval) ?? now).timeIntervalSince(now))
        guard wait > 0 else {
            pendingReload?.cancel()
            pendingReload = nil
            reload()
            return
        }
        guard pendingReload == nil else { return }
        pendingReload = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.pendingReload = nil
            self.reload()
        }
    }

    private func reload() {
        lastReload = Date()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
#endif
