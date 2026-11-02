#if os(macOS)
import AppKit
import SwiftUI
import MurmurCore

/// Everything Compose has written, with what was said, searchable and editable; and every
/// meeting's notes, searchable and read-only.
@MainActor
final class LibraryWindowController {
    let model = LibraryModel()
    private var window: NSWindow?

    func show(store: LibraryStore, meetings: MeetingStore, section: LibrarySection? = nil) {
        model.store = store
        model.meetingStore = meetings
        if let section { model.section = section }
        model.reload()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Library"
            window.contentView = NSHostingView(rootView: LibraryView(model: model))
            window.contentMinSize = NSSize(width: 720, height: 440)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("MurmurLibrary")
            if window.frame.origin == .zero { window.center() }
            self.window = window
        }
        // Murmur has no Dock icon; bring the window forward explicitly.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Picks up a piece Compose just saved, if the window is open.
    func refresh() {
        guard window?.isVisible == true else { return }
        model.reload()
    }
}

enum LibrarySection: String, CaseIterable {
    case compose = "Compose"
    case meetings = "Meetings"
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published private(set) var entries: [LibraryEntry] = []
    @Published var selection: UUID?
    @Published var query = ""
    @Published var section: LibrarySection = .compose
    @Published private(set) var meetings: [MeetingFile] = []
    @Published var meetingSelection: URL?
    var store: LibraryStore?
    var meetingStore: MeetingStore?

    var filteredMeetings: [MeetingFile] {
        let words = query.split(separator: " ").map(String.init)
        return meetings.filter { meeting in words.allSatisfy { meeting.matches($0) } }
    }

    var selectedMeeting: MeetingFile? { meetings.first { $0.url == meetingSelection } }
    /// An edit not yet written to disk.
    private var dirty: LibraryEntry?
    private var pendingSave: Task<Void, Never>?

    var filtered: [LibraryEntry] {
        let words = query.lowercased().split(separator: " ")
        guard !words.isEmpty else { return entries }
        return entries.filter { entry in
            let haystack = (entry.text + " " + entry.transcript + " " + (entry.app ?? "")).lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    var selected: LibraryEntry? { entries.first { $0.id == selection } }

    func reload() {
        flush()
        entries = store?.list() ?? []
        if selected == nil { selection = entries.first?.id }
        meetings = meetingStore?.list() ?? []
        if selectedMeeting == nil { meetingSelection = meetings.first?.url }
    }

    /// Edits are saved shortly after typing stops (or at once when another piece is edited).
    func edit(_ id: UUID, text: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].text != text else { return }
        if dirty?.id != id { flush() }
        entries[index].text = text
        dirty = entries[index]
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        guard let entry = dirty else { return }
        dirty = nil
        if let saved = try? store?.save(entry), let i = entries.firstIndex(where: { $0.id == saved.id }) {
            entries[i].fileURL = saved.fileURL
        }
    }

    func delete(_ entry: LibraryEntry) {
        if dirty?.id == entry.id { dirty = nil }
        try? store?.delete(entry)
        let index = entries.firstIndex { $0.id == entry.id } ?? 0
        entries.removeAll { $0.id == entry.id }
        selection = entries.isEmpty ? nil : entries[min(index, entries.count - 1)].id
    }

    func copy(_ entry: LibraryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text.isEmpty ? entry.transcript : entry.text, forType: .string)
    }

    func reveal(_ entry: LibraryEntry) {
        if let url = entry.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func copySummary(_ meeting: MeetingFile) {
        guard let summary = meeting.shareableSummary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    func copy(_ meeting: MeetingFile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(meeting.markdown, forType: .string)
    }

    func openFolder() {
        guard let folder = section == .meetings ? meetingStore?.folder : store?.folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 420)
        } detail: {
            detail
        }
        .frame(minWidth: 720, minHeight: 440)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        Group {
            if model.section == .compose { composeList } else { meetingList }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Show", selection: $model.section) {
                ForEach(LibrarySection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
        .searchable(text: $model.query, placement: .sidebar,
                    prompt: model.section == .meetings ? "Search meetings" : "Search writing")
    }

    private var composeList: some View {
        List(selection: $model.selection) {
            ForEach(DayGroup.group(model.filtered) { $0.created }) { day in
                Section(day.group.title()) {
                    ForEach(day.items) { entry in
                        ComposeRow(entry: entry)
                            .tag(entry.id)
                            .contextMenu {
                                Button("Copy") { model.copy(entry) }
                                Button("Show in Finder") { model.reveal(entry) }
                                Divider()
                                Button("Delete", role: .destructive) { model.delete(entry) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { if let entry = model.selected { model.delete(entry) } }
        .overlay {
            if model.filtered.isEmpty, !model.query.isEmpty { ContentUnavailableView.search(text: model.query) }
        }
    }

    private var meetingList: some View {
        List(selection: $model.meetingSelection) {
            ForEach(DayGroup.group(model.filteredMeetings) { $0.date }) { day in
                Section(day.group.title()) {
                    ForEach(day.items) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(meeting.url)
                            .contextMenu {
                                Button("Copy Summary") { model.copySummary(meeting) }
                                Button("Copy All") { model.copy(meeting) }
                                Button("Open") { NSWorkspace.shared.open(meeting.url) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.url]) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if model.filteredMeetings.isEmpty, !model.query.isEmpty { ContentUnavailableView.search(text: model.query) }
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        if model.section == .meetings {
            if let meeting = model.selectedMeeting {
                MeetingDetail(meeting: meeting, model: model).id(meeting.url)
            } else {
                ContentUnavailableView {
                    Label(model.meetings.isEmpty ? "No meeting notes yet" : "Pick a meeting", systemImage: "person.2.wave.2")
                } description: {
                    Text("Start Meeting Notes from the menu bar or with its shortcut. Each meeting's transcript and summary is kept here.")
                } actions: {
                    Button("Open Meetings Folder") { model.openFolder() }
                }
            }
        } else if let entry = model.selected {
            LibraryDetail(entry: entry, model: model).id(entry.id)
        } else {
            ContentUnavailableView {
                Label(model.entries.isEmpty ? "Nothing composed yet" : "Pick a piece", systemImage: "sparkles")
            } description: {
                Text("Hold fn⌃⌥ and talk it through. Everything Compose writes is kept here, with what you said.")
            } actions: {
                Button("Open Library Folder") { model.openFolder() }
            }
        }
    }

    /// The summary's first line, or that it is still being recorded.
    static func preview(_ meeting: MeetingFile) -> String {
        let line = meeting.summary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-*• ")) }
            .first { !$0.isEmpty && $0.lowercased() != "summary" }
        return line.map { String($0).replacingOccurrences(of: "**", with: "") } ?? "No summary"
    }

    static func subtitle(_ entry: LibraryEntry) -> String {
        let date = entry.created.formatted(date: .abbreviated, time: .shortened)
        return ([date, entry.style.title] + (entry.app.map { [$0] } ?? [])).joined(separator: " · ")
    }

    /// The time for today's items, the date for older ones.
    static func shortDate(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct ComposeRow: View {
    let entry: LibraryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.title).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text(LibraryView.shortDate(entry.created)).font(.caption).foregroundStyle(.secondary)
            }
            Text(Self.preview(entry)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 6) {
                StyleChip(style: entry.style)
                if let app = entry.app { Text(app).font(.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .padding(.vertical, 4)
    }

    /// The writing (or what was said), as one plain line without Markdown marks.
    static func preview(_ entry: LibraryEntry) -> String {
        let source = entry.text.isEmpty ? entry.transcript : entry.text
        return source.split(whereSeparator: \.isNewline).dropFirst(entry.text.isEmpty ? 0 : 1)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-*>• ")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: "**", with: "")
    }
}

private struct MeetingRow: View {
    let meeting: MeetingFile

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(meeting.title).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text(LibraryView.shortDate(meeting.date)).font(.caption).foregroundStyle(.secondary)
            }
            Text(LibraryView.preview(meeting)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 4)
    }
}

/// Icon buttons along the top of a detail page; they fit any window width.
private struct ActionButton: View {
    let title: String
    let systemImage: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) { Image(systemName: systemImage).frame(width: 18, height: 18) }
            .buttonStyle(.borderless)
            .help(title)
            .accessibilityLabel(title)
    }
}

private struct LibraryDetail: View {
    let entry: LibraryEntry
    @ObservedObject var model: LibraryModel
    @State private var draft: String
    @State private var showTranscript = false
    @State private var confirmDelete = false

    init(entry: LibraryEntry, model: LibraryModel) {
        self.entry = entry
        self.model = model
        _draft = State(initialValue: entry.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if entry.text.isEmpty && draft.isEmpty {
                Text("This one was never written (no model, or the panel was closed first). What you said is below; type here to keep your own version.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 24).padding(.bottom, 8)
            }
            TextEditor(text: $draft)
                .font(.system(size: 14))
                .lineSpacing(3)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 19)
                .onChange(of: draft) { _, text in model.edit(entry.id, text: text) }
            Divider()
            DisclosureGroup("What I said", isExpanded: $showTranscript) {
                ScrollView {
                    Text(entry.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
        }
        .confirmationDialog("Delete this piece?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(entry) }
        } message: {
            Text("Its file is removed from the library folder.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.title).font(.title2.weight(.bold)).lineLimit(2)
                HStack(spacing: 10) {
                    StyleChip(style: entry.style)
                    if let app = entry.app { Label(app, systemImage: "macwindow") }
                    Label(entry.created.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                    if let name = entry.model { Label(name, systemImage: "cpu").lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 14) {
                CopyButton(title: "Copy", text: draft.isEmpty ? entry.transcript : draft, iconOnly: true)
                ShareLink(item: draft.isEmpty ? entry.transcript : draft) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless).help("Share")
                ActionButton(title: "Show in Finder", systemImage: "folder") { model.reveal(entry) }
                ActionButton(title: "Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }
}

private struct MeetingDetail: View {
    let meeting: MeetingFile
    @ObservedObject var model: LibraryModel

    var body: some View {
        let document = MarkdownBlocks.sections(MarkdownBlocks.parse(meeting.markdown))
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(details: Self.details(document.sections.first))
                ForEach(Array(document.preamble.enumerated()), id: \.offset) { _, block in MarkdownView.row(block) }
                ForEach(Array(document.sections.dropFirst().enumerated()), id: \.offset) { _, section in
                    if section.title.lowercased() == "transcript" {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Transcript").font(.title3.weight(.semibold))
                            MarkdownView(blocks: section.blocks)
                        }
                    } else {
                        Card {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(section.title, systemImage: section.title.lowercased() == "summary" ? "text.alignleft" : "doc.text")
                                    .font(.title3.weight(.semibold))
                                MarkdownView(blocks: section.blocks)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    /// The first section is the title, with the details line ("Sep 23 · 25 min") under it.
    static func details(_ titleSection: MarkdownSection?) -> String? {
        for case let .paragraph(text) in titleSection?.blocks ?? [] { return text }
        return nil
    }

    private func header(details: String?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(meeting.title).font(.title.weight(.bold)).lineLimit(2)
                Text(details.map { MarkdownView.inline($0) } ?? AttributedString(meeting.date.formatted(date: .long, time: .shortened)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 14) {
                CopyButton(title: "Copy Summary", text: meeting.shareableSummary, iconOnly: true, systemImage: "text.badge.checkmark")
                CopyButton(title: "Copy All", text: meeting.markdown, iconOnly: true)
                ShareLink(item: meeting.url) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.borderless).help("Share")
                ActionButton(title: "Open in Editor", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(meeting.url) }
                ActionButton(title: "Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([meeting.url])
                }
            }
            .padding(.top, 6)
        }
    }
}

/// A button that puts `text` on the clipboard and says "Copied" for a moment. Disabled without text.
/// `iconOnly` draws it as an icon with the title as its tooltip.
struct CopyButton: View {
    let title: String
    let text: String?
    var iconOnly = false
    var systemImage = "doc.on.doc"
    @State private var copied = false

    var body: some View {
        if iconOnly {
            button.buttonStyle(.borderless)
        } else {
            button
        }
    }

    private var button: some View {
        Button {
            guard let text else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            if iconOnly {
                Image(systemName: copied ? "checkmark" : systemImage)
                    .frame(width: 18, height: 18)
                    .contentTransition(.symbolEffect(.replace))
            } else {
                Text(copied ? "Copied" : title)
            }
        }
        .help(copied ? "Copied" : title)
        .accessibilityLabel(copied ? "Copied" : title)
        .disabled(text == nil)
    }
}
#endif
