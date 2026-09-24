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
            VStack(spacing: 0) {
                Picker("", selection: $model.section) {
                    ForEach(LibrarySection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding([.horizontal, .top], 8)
                TextField("Search", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .padding(8)
                if model.section == .compose {
                    List(model.filtered, selection: $model.selection) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title).lineLimit(1)
                            Text(Self.subtitle(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(entry.id)
                    }
                } else {
                    List(model.filteredMeetings, selection: $model.meetingSelection) { meeting in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(meeting.date.formatted(date: .abbreviated, time: .shortened)).lineLimit(1)
                            Text(Self.preview(meeting)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .padding(.vertical, 2)
                        .tag(meeting.url)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 280)
        } detail: {
            if model.section == .meetings {
                if let meeting = model.selectedMeeting {
                    MeetingDetail(meeting: meeting, model: model).id(meeting.url)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2.wave.2").font(.largeTitle).foregroundStyle(.purple)
                        Text(model.meetings.isEmpty ? "No meeting notes yet" : "Pick a meeting").font(.headline)
                        Text("Start Meeting Notes from the menu bar. Each meeting's transcript and summary is kept here.")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
                        Button("Open Meetings Folder") { model.openFolder() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if let entry = model.selected {
                LibraryDetail(entry: entry, model: model).id(entry.id)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(.purple)
                    Text(model.entries.isEmpty ? "Nothing composed yet" : "Pick a piece").font(.headline)
                    Text("Hold fn⌃⌥ and talk it through. Everything Compose writes is kept here, with what you said.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 320)
                    Button("Open Library Folder") { model.openFolder() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
    }

    /// The summary's first line, or that it is still being recorded.
    static func preview(_ meeting: MeetingFile) -> String {
        let line = meeting.summary.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-*• ")) }
            .first { !$0.isEmpty }
        return line ?? "No summary"
    }

    static func subtitle(_ entry: LibraryEntry) -> String {
        let date = entry.created.formatted(date: .abbreviated, time: .shortened)
        return ([date, entry.style.title] + (entry.app.map { [$0] } ?? [])).joined(separator: " · ")
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(LibraryView.subtitle(entry) + (entry.model.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { model.copy(entry) }
                Button("Show in Finder") { model.reveal(entry) }
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .help("Delete")
            }
            if entry.text.isEmpty && draft.isEmpty {
                Text("This one was never written (no model, or the panel was closed first). What you said is below; type here to keep your own version.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .onChange(of: draft) { _, text in model.edit(entry.id, text: text) }
            DisclosureGroup("What I said", isExpanded: $showTranscript) {
                ScrollView {
                    Text(entry.transcript).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .confirmationDialog("Delete this piece?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.delete(entry) }
        } message: {
            Text("Its file is removed from the library folder.")
        }
    }
}
private struct MeetingDetail: View {
    let meeting: MeetingFile
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title).font(.title3.weight(.semibold)).lineLimit(1)
                    Text(meeting.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { model.copy(meeting) }
                Button("Open") { NSWorkspace.shared.open(meeting.url) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([meeting.url]) }
            }
            ScrollView {
                Text(Self.rendered(meeting.markdown))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        }
        .padding(16)
    }

    /// Bold, italics and links rendered; headings and lists stay as written.
    static func rendered(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
#endif
