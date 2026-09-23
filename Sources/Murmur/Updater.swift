#if os(macOS)
import AppKit
import Security
import MurmurCore

/// Finds newer releases on GitHub and installs them in place: download the zip, check that the new
/// app is signed by the same developer and notarized, swap it in, relaunch. Settings, models and
/// permissions carry over because the signature's identity does not change.
@MainActor
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case installing(String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// Called when `state` changes, for the menu.
    var onChange: (() -> Void)?

    private var repository = UpdatesConfig().repository
    private var timer: Timer?
    private var checking = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var available: ReleaseInfo? {
        if case let .available(release) = state { return release }
        return nil
    }

    /// Checks shortly after launch and then every six hours, if the settings allow it.
    func configure(_ config: UpdatesConfig) {
        repository = config.repository
        timer?.invalidate()
        timer = nil
        guard config.checkAutomatically else { return }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await self?.check(userInitiated: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.check(userInitiated: false) }
        }
    }

    /// From the menu, or on the timer. A background check never replaces a visible error or an install.
    func check(userInitiated: Bool) async {
        guard !checking else { return }
        if case .installing = state { return }
        checking = true
        defer { checking = false }
        if userInitiated { set(.checking) }
        do {
            let latest = try await UpdateChecker(repository: repository).latest()
            if UpdateChecker.isNewer(latest, than: currentVersion) {
                set(.available(latest))
            } else if userInitiated || available != nil {
                set(.upToDate)
            }
        } catch {
            if userInitiated { set(.failed("Could not check for updates: \(Self.describe(error))")) }
        }
    }

    func install(_ release: ReleaseInfo) {
        if case .installing = state { return }
        set(.installing("Downloading \(release.tag)…"))
        Task { [weak self] in
            guard let self else { return }
            do {
                let newApp = try await self.downloadAndVerify(release)
                self.set(.installing("Installing \(release.tag)…"))
                try self.replaceRunningApp(with: newApp)
                self.set(.installing("Restarting…"))
                // Quitting saves a running meeting first (AppDelegate.applicationShouldTerminate).
                self.relaunch()
            } catch {
                self.set(.failed("Update failed: \(Self.describe(error)) You can download it from the release page instead."))
            }
        }
    }

    func openReleasePage() {
        let url = available?.page ?? URL(string: "https://github.com/\(repository)/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Steps

    private func downloadAndVerify(_ release: ReleaseInfo) async throws -> URL {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("MurmurUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (downloaded, response) = try await URLSession.shared.download(from: release.download)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdaterError("the download answered HTTP \(http.statusCode).")
        }
        let zip = work.appendingPathComponent("Murmur.zip")
        try FileManager.default.moveItem(at: downloaded, to: zip)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        let newApp = work.appendingPathComponent("Murmur.app")
        guard FileManager.default.fileExists(atPath: newApp.path) else { throw UpdaterError("the zip has no Murmur.app.") }

        // The whole point: only an app from the same developer, intact and notarized, replaces this one.
        guard let ours = Self.teamIdentifier(of: Bundle.main.bundleURL) else {
            throw UpdaterError("this copy of Murmur is not signed with a Developer ID, so it cannot verify the update.")
        }
        guard Self.teamIdentifier(of: newApp) == ours else {
            throw UpdaterError("the download is not signed by the same developer.")
        }
        guard Bundle(url: newApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdaterError("the download is a different app.")
        }
        try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        try await Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", newApp.path])
        return newApp
    }

    /// Swaps the bundle on disk. The running process keeps its already-open files until it quits.
    private func replaceRunningApp(with newApp: URL) throws {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw UpdaterError("Murmur's folder (\(current.deletingLastPathComponent().path)) is not writable.")
        }
        _ = try FileManager.default.replaceItemAt(current, withItemAt: newApp, backupItemName: nil, options: [])
    }

    private func relaunch() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Wait for this process to exit, then open the new copy.
        process.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private func set(_ newState: State) {
        state = newState
        onChange?()
    }

    // MARK: Helpers

    /// The Team ID of the certificate an app is signed with; nil for ad-hoc or self-signed builds.
    static func teamIdentifier(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            process.terminationHandler = { finished in
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = (tool as NSString).lastPathComponent
                    continuation.resume(throwing: UpdaterError("\(name) refused it\(message.isEmpty ? "" : ": \(message)")."))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? UpdaterError { return error.description }
        if let error = error as? UpdateError { return error.description }
        if let error = error as? URLError { return error.localizedDescription + "." }
        return "\(error)."
    }
}

private struct UpdaterError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
