#if os(macOS)
import AppKit
import SwiftUI
import WidgetKit
import MurmurCore
import MurmurWidgetViews

/// `Murmur --snapshots <folder>`: the screenshot tests. Opens every window and state with made-up
/// data, without starting anything (no hotkey, microphone, models, update check or network), saves
/// each as a PNG in <folder> with a report.md, and exits with 1 if any of them drew nothing, as
/// 0.2.5's Settings did. CI runs it on every push and attaches the folder to the run, so a design
/// change can be looked at without installing it.
@MainActor
enum Snapshots {
    static func folder(in arguments: [String] = CommandLine.arguments) -> URL? {
        guard let index = arguments.firstIndex(of: "--snapshots"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }

    static func run(into folder: URL) async -> Int32 {
        let camera = Camera(folder: folder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            print("Cannot write to \(folder.path): \(error)")
            return 2
        }
        if await camera.calibrate() {
            await shootEverything(camera)
        }
        camera.writeReport()
        print(camera.failures.isEmpty ? "All \(camera.rows.count) screenshots show content."
              : "Failed: \(camera.failures.joined(separator: ", "))")
        return camera.failures.isEmpty ? 0 : 1
    }

    /// Far enough to reach the right or bottom edge of any window; regions are clipped to the image.
    static let edge: CGFloat = 100_000

    private static func shootEverything(_ camera: Camera) async {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MurmurSnapshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let controller = DictationController()
        controller.loadForSnapshots(sampleConfig())
        // Each window lives only as long as its controller; keep them all until the end.
        var controllers: [AnyObject] = [controller]
        defer { withExtendedLifetime(controllers) {} }

        // Settings: every page. The sidebar and the page must each show something.
        for tab in SettingsTab.allCases {
            controller.showSettings(tab: tab)
            await camera.shoot("settings-\(tab.rawValue.lowercased())", window(titled: "Murmur Settings"),
                               regions: [("sidebar", CGRect(x: 0, y: 0, width: 200, height: edge)),
                                         ("page", CGRect(x: 220, y: 0, width: edge, height: edge))])
        }

        // Library: writing and meetings, with a piece and a meeting selected; then empty.
        let libraryFolder = work.appendingPathComponent("Library")
        let meetingsFolder = work.appendingPathComponent("Meetings")
        writeSampleLibrary(to: libraryFolder)
        writeSampleMeeting(to: meetingsFolder)
        let library = LibraryWindowController()
        controllers.append(library)
        let listAndDetail: [(String, CGRect)] = [("list", CGRect(x: 0, y: 0, width: 240, height: edge)),
                                                 ("detail", CGRect(x: 320, y: 0, width: edge, height: edge))]
        library.show(store: LibraryStore(folder: libraryFolder), meetings: MeetingStore(folder: meetingsFolder), section: .compose)
        await camera.shoot("library-writing", window(titled: "Library"), regions: listAndDetail)
        library.show(store: LibraryStore(folder: libraryFolder), meetings: MeetingStore(folder: meetingsFolder), section: .meetings)
        await camera.shoot("library-meetings", window(titled: "Library"), regions: listAndDetail)
        let emptyLibrary = LibraryWindowController()
        controllers.append(emptyLibrary)
        emptyLibrary.show(store: LibraryStore(folder: work.appendingPathComponent("Empty")),
                          meetings: MeetingStore(folder: work.appendingPathComponent("NoMeetings")), section: .compose)
        await camera.shoot("library-empty", window(titled: "Library"))

        let live = MeetingLiveWindowController()
        controllers.append(live)
        await camera.shoot("live-transcript", live.showPreview(turns: sampleTurns, elapsed: 754, pending: 1))

        // The menu's card, on the menu's own material.
        for (name, status, color, today) in [("menu-card", "Ready", Color.green, "1,180 words today · 21 min saved"),
                                             ("menu-card-attention", "Needs Attention", Color.orange, "Nothing dictated yet today")] {
            let header = NSHostingView(rootView: MenuHeader(status: status, color: color, today: today, hints: controller.modeHints))
            header.frame = NSRect(origin: .zero, size: header.fittingSize)
            let material = NSVisualEffectView(frame: header.frame)
            material.material = .menu
            material.state = .active
            material.addSubview(header)
            await camera.shoot(name, makeWindow("Menu", header.fittingSize, content: material))
        }

        await shootPill(camera)

        let compose = ComposeController(inserter: TextInserter())
        controllers.append(compose)
        let session = ComposeSession(context: CleanupContext(appName: "Mail", windowTitle: nil), target: nil)
        session.transcript = "tell sam the launch moves to the fourteenth because the beta needs another week and ask if that still works for the press call"
        session.text = "Subject: Launch moves to the 14th\n\nHi Sam,\n\nThe launch moves to the 14th: the beta needs one more week. "
            + "Does that still work for the press call?\n\nThanks,\nAlex"
        session.style = .email
        session.styleNote = "for Mail"
        session.modelName = "Ollama qwen3:8b"
        session.timing = "0.9 s + 4.2 s"
        session.phase = .done
        await camera.shoot("compose", hosting("Compose", NSSize(width: 640, height: 460), ComposeView(session: session, controller: compose)))

        let howTo = HowToWindowController()
        controllers.append(howTo)
        howTo.show(hotkey: "fn", hasModes: true)
        await camera.shoot("how-to", window(titled: "How to Use Murmur"))

        let setup = SetupWindowController(controller: controller)
        controllers.append(setup)
        setup.show()
        await camera.shoot("setup", window(titled: "Set up Murmur"))

        let offer = CallOfferView(title: "Take notes for this call?",
                                  message: "Looks like a call started in FaceTime. Murmur can transcribe it and write a summary when it ends. Let the others know.",
                                  primary: "Take Notes", secondary: "Not Now", never: "Don't Ask Again",
                                  accept: {}, later: {}, neverAction: {})
        let offerView = NSHostingView(rootView: offer)
        await camera.shoot("call-offer", makeWindow("Call", offerView.fittingSize, content: offerView))

        await shootWidgets(camera)
    }

    private static func shootPill(_ camera: Camera) async {
        let pill = PillController()
        defer { withExtendedLifetime(pill) {} }
        let model = pill.model
        model.hotkeyName = "fn"
        let voice: [Float] = [0.05, 0.2, 0.45, 0.7, 0.4, 0.25, 0.6, 0.9, 0.5, 0.3, 0.15, 0.35, 0.65, 0.8, 0.45,
                              0.2, 0.1, 0.3, 0.55, 0.75, 0.6, 0.35, 0.2, 0.4]
        let states: [(String, PillPhase, DictationMode, String, TimeInterval)] = [
            ("pill-listening", .recording(.hold), .dictate, "", 300),
            ("pill-clean-up", .recording(.hold), .clean, "", 300),
            ("pill-hands-free-words", .recording(.handsFree), .dictate,
             "so the next step is to send the deck to Sam by Friday", 200),
            ("pill-hands-free-ending", .recording(.handsFree), .compose, "", 18),
            ("pill-transcribing", .processing("Transcribing"), .dictate, "", 300),
            ("pill-status", .status("Writing the summary…"), .dictate, "", 300),
            ("pill-message", .message("No speech heard", isError: false), .dictate, "", 300),
            ("pill-error", .message("Groq: the API key was not accepted", isError: true), .dictate, "", 300),
            ("pill-done", .done("42 words"), .dictate, "", 300),
        ]
        for (name, phase, mode, words, remaining) in states {
            model.mode = mode
            model.liveText = words
            model.elapsed = 42
            model.remaining = remaining
            pill.show(phase)
            for level in voice { model.level = level }
            await camera.shoot(name, pill.window, wait: 0.9)
        }
        pill.hide()
    }

    private static func shootWidgets(_ camera: Camera) async {
        let now = Date()
        var recording = WidgetSnapshot.sample(now: now)
        recording.meetingStarted = now.addingTimeInterval(-754)
        let shots: [(String, WidgetFamily, MurmurEntry)] = [
            ("widget-small", .systemSmall, MurmurEntry(date: now, snapshot: .sample(now: now), isReady: true)),
            ("widget-small-recording", .systemSmall, MurmurEntry(date: now, snapshot: recording, isReady: true)),
            ("widget-medium", .systemMedium, MurmurEntry(date: now, snapshot: .sample(now: now), isReady: true)),
            ("widget-medium-recording", .systemMedium, MurmurEntry(date: now, snapshot: recording, isReady: true)),
            ("widget-not-ready", .systemSmall, MurmurEntry(date: now, snapshot: .sample(now: now), isReady: false)),
        ]
        for (name, family, entry) in shots {
            // About the sizes macOS gives each family; the system adds the margins itself.
            let size = family == .systemMedium ? NSSize(width: 344, height: 160) : NSSize(width: 160, height: 160)
            let widget = ZStack {
                WidgetBackground()
                TodayWidgetView(entry: entry, size: family).padding(14)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            await camera.shoot(name, hosting("Widget", size, widget))
        }
    }

    // MARK: Windows

    static func window(titled title: String) -> NSWindow? {
        NSApp.windows.first { $0.title == title && $0.isVisible }
    }

    static func makeWindow(_ title: String, _ size: NSSize, content: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.center()
        window.orderFrontRegardless()
        return window
    }

    static func hosting<V: View>(_ title: String, _ size: NSSize, _ view: V) -> NSWindow {
        makeWindow(title, size, content: NSHostingView(rootView: view.frame(width: size.width, height: size.height)))
    }

    // MARK: Sample data

    static func sampleConfig() -> Config {
        var config = Config()
        config.transcription.vocabulary = ["Kubernetes", "Siobhan", "Murmur"]
        config.transcription.corrections = [Correction(heard: "cloud code", write: "Claude Code")]
        config.snippets = [Snippet(say: "my email", insert: "name@example.com"),
                           Snippet(say: "sign off", insert: "Thanks,\nAlex")]
        return config
    }

    static let sampleTurns: [MeetingSegment] = [
        MeetingSegment(start: 12, speaker: .others, text: "Thanks for joining. Can we start with the launch date?"),
        MeetingSegment(start: 31, speaker: .me, text: "Sure. The beta needs one more week, so I'd move the launch to the 14th."),
        MeetingSegment(start: 58, speaker: .others, text: "That works. Can you send the updated deck by Friday?"),
        MeetingSegment(start: 74, speaker: .me, text: "Yes, I'll send it Thursday and copy Siobhan."),
    ]

    static func writeSampleLibrary(to folder: URL) {
        let store = LibraryStore(folder: folder)
        let now = Date()
        let entries = [
            LibraryEntry(created: now.addingTimeInterval(-20 * 60), style: .email, app: "Mail", model: "Ollama qwen3:8b",
                         text: "Subject: Launch moves to the 14th\n\nHi Sam,\n\nThe launch moves to the 14th: the beta needs one more week.\n\nThanks,\nAlex",
                         transcript: "tell sam the launch moves to the fourteenth because the beta needs another week"),
            LibraryEntry(created: now.addingTimeInterval(-26 * 3600), style: .message, app: "Slack", model: "Groq llama-3.3-70b-versatile",
                         text: "Running 5 min late, start without me!", transcript: "tell them I'm running five minutes late"),
            LibraryEntry(created: now.addingTimeInterval(-4 * 86_400), style: .bullets, app: "Notes", model: "Ollama qwen3:8b",
                         text: "- Book the venue\n- Draft the invite\n- Confirm catering by Monday",
                         transcript: "book the venue draft the invite and confirm catering by monday"),
        ]
        for entry in entries { _ = try? store.save(entry) }
    }

    static func writeSampleMeeting(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let summary = """
        ### Summary
        - The launch moves to the **14th**: the beta needs one more week.
        - The press call stays on the 16th.
        ### Decisions
        - Beta goes to 40 customers first.
        ### Action items
        - [ ] **Me**: send the updated deck (Thursday)
        - [x] **Sam**: book the room for the press call
        ### Open questions
        - Do we need a second beta wave?
        """
        let date = Date().addingTimeInterval(-3 * 3600)
        let markdown = MeetingNotes.markdown(title: "Weekly sync",
                                             details: "**Started:** today · **Length:** 25 min · **Transcribed by:** whisper.cpp",
                                             summary: summary, transcript: MeetingTranscript(segments: sampleTurns))
        try? Data(markdown.utf8).write(to: folder.appendingPathComponent(MeetingNotes.fileName(for: date)))
    }
}

/// Takes the screenshots and keeps the results.
@MainActor
final class Camera {
    enum Method: String {
        /// What the screen shows, glass and materials included.
        case windowServer = "the window server"
        /// AppKit drawing the window's views itself, when the window server cannot be asked.
        case appKit = "AppKit drawing"
    }

    struct Row {
        var name: String
        var size: String
        var detail: String
        var passed: Bool
        var note: String
    }

    let folder: URL
    private(set) var method: Method = .windowServer
    private(set) var rows: [Row] = []
    private(set) var failures: [String] = []

    init(folder: URL) {
        self.folder = folder
    }

    /// Shows the window, waits for layout and animations, then saves and checks it. `regions` are in
    /// points of the window's content from its top left; each must show something on its own.
    func shoot(_ name: String, _ window: NSWindow?, regions: [(String, CGRect)] = [], wait: Double = 0.8) async {
        guard let window else {
            record(Row(name: name, size: "–", detail: "", passed: false, note: "the window did not open"))
            return
        }
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        guard let (image, results) = check(window, using: method, regions: regions) else {
            record(Row(name: name, size: "–", detail: "", passed: false, note: "could not capture it"))
            return
        }
        // Out of the way of the next one; showing it again brings it back.
        window.orderOut(nil)
        save(image, as: name)
        let blank = results.filter { $0.1.isBlank }.map(\.0)
        record(Row(name: name, size: "\(image.width)×\(image.height)", detail: Self.describe(results), passed: blank.isEmpty,
                   note: blank.isEmpty ? "" : "drew nothing: \(blank.joined(separator: ", "))"))
    }

    /// Before trusting any result: a window with text must show content, and an empty window and an
    /// empty blurred sidebar (0.2.5's Settings) must not. Uses AppKit drawing if the window server
    /// cannot capture Murmur's own windows here.
    func calibrate() async -> Bool {
        let label = NSTextField(labelWithString: "Murmur screenshot check")
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.frame = NSRect(x: 30, y: 60, width: 360, height: 34)
        let textContent = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 160))
        textContent.addSubview(label)
        let text = Snapshots.makeWindow("Check: text", textContent.frame.size, content: textContent)
        let empty = Snapshots.makeWindow("Check: empty", NSSize(width: 420, height: 160), content: NSView())
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .active
        let blurred = Snapshots.makeWindow("Check: blurred sidebar", NSSize(width: 420, height: 160), content: sidebar)
        defer { [text, empty, blurred].forEach { $0.close() } }
        try? await Task.sleep(nanoseconds: 800_000_000)

        if check(text, using: .windowServer, regions: [])?.results.first?.1.isBlank != false {
            method = .appKit
        }
        guard let (textImage, textResults) = check(text, using: method, regions: []), let textResult = textResults.first?.1,
              !textResult.isBlank else {
            record(Row(name: "check-text", size: "–", detail: "", passed: false, note: "neither the window server nor AppKit shows text"))
            return false
        }
        save(textImage, as: "check-text")
        record(Row(name: "check-text", size: "\(textImage.width)×\(textImage.height)", detail: Self.describe(textResults),
                   passed: true, note: "must show content"))
        var reliable = true
        for (name, window) in [("check-empty", empty), ("check-blurred-sidebar", blurred)] {
            guard let (image, results) = check(window, using: method, regions: []) else { continue }
            save(image, as: name)
            let blank = results.allSatisfy { $0.1.isBlank }
            reliable = reliable && blank
            record(Row(name: name, size: "\(image.width)×\(image.height)", detail: Self.describe(results), passed: blank,
                       note: blank ? "must be blank" : "should be blank: the check would miss a window that drew nothing"))
        }
        return reliable
    }

    private func record(_ row: Row) {
        rows.append(row)
        if !row.passed { failures.append(row.name) }
        print("\(row.passed ? "✓" : "✗") \(row.name) \(row.detail) \(row.note)")
    }

    private func check(_ window: NSWindow, using method: Method,
                       regions: [(String, CGRect)]) -> (image: CGImage, results: [(String, SnapshotCheck.Result)])? {
        guard let shot = capture(window, using: method) else { return nil }
        let pixels = Self.pixels(of: shot.image)
        let areas = regions.isEmpty ? [("window", CGRect(x: 0, y: 0, width: Snapshots.edge, height: Snapshots.edge))] : regions
        // 4 points in from every side: the window's outline, rounded corners and the line under the
        // title bar are not content.
        let margin = Int((4 * shot.scale).rounded())
        let results = areas.map { name, rect -> (String, SnapshotCheck.Result) in
            let left = max(margin, Int(rect.minX * shot.scale))
            let top = shot.contentTop + max(margin, Int(rect.minY * shot.scale))
            let right = min(shot.image.width - margin, Int(rect.maxX * shot.scale))
            let bottom = min(shot.image.height - margin, shot.contentTop + Int(rect.maxY * shot.scale))
            let region = SnapshotCheck.Region(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
            return (name, SnapshotCheck.analyze(rgba: pixels, width: shot.image.width, height: shot.image.height, region: region))
        }
        return (image: shot.image, results: results)
    }

    /// The image, where the window's content starts in it (below the title bar), and pixels per point.
    private func capture(_ window: NSWindow, using method: Method) -> (image: CGImage, contentTop: Int, scale: CGFloat)? {
        switch method {
        case .windowServer:
            guard let image = Self.windowServerImage(of: window), window.frame.width > 0 else { return nil }
            let scale = CGFloat(image.width) / window.frame.width
            let contentHeight = window.contentView?.frame.height ?? window.frame.height
            return (image, Int(((window.frame.height - contentHeight) * scale).rounded()), scale)
        case .appKit:
            guard let view = window.contentView, view.bounds.width > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let image = rep.cgImage else { return nil }
            return (image, 0, CGFloat(image.width) / view.bounds.width)
        }
    }

    /// CGWindowListCreateImage, looked up when it runs: Apple has deprecated it in favor of
    /// ScreenCaptureKit (which needs a permission CI does not have), and newer SDKs may hide it.
    /// An app may always capture its own windows with it.
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        let options = CGWindowImageOption([.boundsIgnoreFraming, .bestResolution]).rawValue
        return create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), options)?
            .takeRetainedValue()
    }

    private static func pixels(of image: CGImage) -> [UInt8] {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return bytes
    }

    private func save(_ image: CGImage, as name: String) {
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        try? png?.write(to: folder.appendingPathComponent(name + ".png"))
    }

    private static func describe(_ results: [(String, SnapshotCheck.Result)]) -> String {
        results.map { "\($0.0) \(String(format: "%.2f", $0.1.edges * 100))%" }.joined(separator: ", ")
    }

    /// report.md: one row a screenshot, for the CI run's summary.
    func writeReport() {
        var text = "## Screenshots\n\n"
        text += "Captured with \(method.rawValue). Each checked area must have edges (text, icons, controls); "
        text += "under \(String(format: "%.2f", SnapshotCheck.Result.threshold * 100))% means it drew nothing. "
        text += "The PNGs are in this run's **screenshots** artifact.\n\n"
        text += "| | Screenshot | Size | Edges | Note |\n|---|---|---|---|---|\n"
        for row in rows {
            text += "| \(row.passed ? "✅" : "❌") | \(row.name) | \(row.size) | \(row.detail) | \(row.note) |\n"
        }
        try? Data(text.utf8).write(to: folder.appendingPathComponent("report.md"))
    }
}
#endif
