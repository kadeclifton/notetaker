import Foundation

/// Which speech-to-text backend to use.
public enum TranscriptionEngine: String, Codable, Sendable, CaseIterable {
    /// Groq if `GROQ_API_KEY` is set, else OpenAI if `OPENAI_API_KEY` is set, else local whisper.cpp.
    case auto
    /// whisper.cpp on this machine. Works offline.
    case local
    case groq
    case openai
}

/// Which LLM cleans up the raw transcript.
public enum CleanupProvider: String, Codable, Sendable, CaseIterable {
    /// Groq, then OpenAI, then Anthropic, whichever has a key, then a local Ollama or LM Studio.
    /// None of those: cleanup is skipped.
    case auto
    case groq
    case openai
    case anthropic
    /// Ollama or LM Studio running on this Mac, found automatically. No key, nothing leaves the machine.
    case local
    /// Any OpenAI-compatible chat endpoint set in `cleanup.baseURL` (llama.cpp server, vLLM, ...).
    case custom
}

public enum InsertionMethod: String, Codable, Sendable, CaseIterable {
    /// Put the text on the pasteboard and send Cmd-V. Fast, works almost everywhere.
    case paste
    /// Synthesize keystrokes. Slower, but never touches the pasteboard for insertion.
    case type
}

public struct Config: Codable, Equatable, Sendable {
    /// Key to hold for push-to-talk; double-tap it for hands-free. See `HotkeySpec`.
    public var hotkey: String = "fn"
    /// What the hotkey does alone, with ⌃, and with ⌃⌥.
    public var modes = ModesConfig()
    public var transcription = TranscriptionConfig()
    public var cleanup = CleanupConfig()
    public var insertion = InsertionConfig()
    public var handsFree = HandsFreeConfig()
    public var timing = TimingConfig()
    public var feedback = FeedbackConfig()
    public var meeting = MeetingConfig()
    public var compose = ComposeConfig()
    public var updates = UpdatesConfig()

    public init() {}
}

public struct TranscriptionConfig: Codable, Equatable, Sendable {
    public var engine: TranscriptionEngine = .auto
    /// ISO-639-1 code such as "en", or "auto" to let Whisper detect it.
    public var language: String = "en"
    /// Names and jargon Whisper tends to misspell. Sent as the initial prompt.
    public var vocabulary: [String] = []
    public var whisperCpp = WhisperCppConfig()
    public var groqModel: String = "whisper-large-v3-turbo"
    public var openaiModel: String = "whisper-1"
    public var timeoutSeconds: Double = 60

    public init() {}
}

public struct WhisperCppConfig: Codable, Equatable, Sendable {
    /// Path to `whisper-cli`. Empty: look in Homebrew's and the usual install locations.
    public var binary: String = ""
    /// Relative paths are inside the settings directory (see `AppPaths`).
    public var model: String = "models/ggml-small.en.bin"
    /// 0 picks a sensible count for this machine.
    public var threads: Int = 0
    /// Run `whisper-server` in the background with the model loaded, so dictation does not wait
    /// for a model load every time. Uses the model's size in memory while Murmur runs.
    public var keepModelLoaded: Bool = true
    /// Local port for that server (it only listens on 127.0.0.1).
    public var serverPort: Int = 47813
    /// Stop that server after this many minutes without dictation, to give its memory back; it
    /// starts again the moment you press the hotkey. 0 keeps it loaded while Murmur runs.
    public var unloadAfterMinutes: Double = 30

    public init() {}
}

public struct CleanupConfig: Codable, Equatable, Sendable {
    public var enabled: Bool = true
    public var provider: CleanupProvider = .auto
    /// Empty: the provider's default (see `CleanupProvider.defaultModel`).
    public var model: String = ""
    /// Only used by the `custom` provider, e.g. "http://localhost:11434/v1".
    public var baseURL: String = ""
    public var timeoutSeconds: Double = 10
    /// Appended to the cleanup prompt, e.g. "Use British spelling."
    public var extraInstructions: String = ""

    public init() {}
}

public struct InsertionConfig: Codable, Equatable, Sendable {
    public var method: InsertionMethod = .paste
    /// false: the transcript stays on the clipboard so you can paste it again.
    /// true: whatever was on the clipboard before is put back after inserting.
    public var restoreClipboard: Bool = false
    /// How long to wait after Cmd-V before restoring the clipboard.
    public var restoreDelayMs: Int = 500

    public init() {}
}

public struct HandsFreeConfig: Codable, Equatable, Sendable {
    /// Any recording (hands-free, or a hold whose key-up got lost) stops after this long.
    public var maxMinutes: Double = 5
    /// What to do with a recording that hit the limit: "transcribe" or "discard".
    public var onTimeLimit: String = "transcribe"

    public init() {}
}

public struct TimingConfig: Codable, Equatable, Sendable {
    /// A press shorter than this is a tap, not a hold.
    public var tapMaxMs: Int = 250
    /// A second press within this long after a tap starts hands-free.
    public var doubleTapWindowMs: Int = 350
    /// With a modifier-only hotkey (like fn), another key pressed this soon after it
    /// means you were typing a shortcut such as fn+arrow, so the recording is dropped.
    public var chordGuardMs: Int = 400

    public init() {}
}

public struct MeetingConfig: Codable, Equatable, Sendable {
    /// Where meeting notes are saved, one Markdown file per meeting.
    public var folder: String = "~/Documents/Murmur Meetings"
    /// Record the call's audio (everyone else) as well as your microphone. Needs the
    /// Screen & System Audio Recording permission.
    public var captureSystemAudio: Bool = true
    /// Audio is transcribed in pieces of about this many seconds while the meeting runs.
    public var chunkSeconds: Double = 30
    /// A recording stops by itself after this long.
    public var maxHours: Double = 4
    public var summarize: Bool = true
    /// Which LLM writes the summary. Same choices as cleanup.provider; "local" keeps it on this Mac.
    public var summaryProvider: CleanupProvider = .auto
    public var summaryModel: String = ""
    public var summaryTimeoutSeconds: Double = 600

    public init() {}
}

public struct ComposeConfig: Codable, Equatable, Sendable {
    /// Which LLM writes. Same choices as cleanup.provider. Compose runs only when you ask for it,
    /// so it gets the most capable model that fits this Mac, not the quick cleanup one.
    public var provider: CleanupProvider = .auto
    /// Empty: pick automatically (see `LocalLLM.Purpose.compose`).
    public var model: String = ""
    /// What to write when neither what you said nor the app says: "auto", "message", "email",
    /// "bullets", "document" or "prompt".
    public var defaultStyle: ComposeStyle = .auto
    /// Long-form rambles run longer than dictation, so they get their own recording limit.
    public var maxMinutes: Double = 15
    public var timeoutSeconds: Double = 180
    /// Every composed piece is kept here with what you said, one Markdown file each.
    public var folder: String = "~/Documents/Murmur Library"
    /// Added to the compose prompt, e.g. "I write in British English."
    public var extraInstructions: String = ""

    public init() {}
}

public struct UpdatesConfig: Codable, Equatable, Sendable {
    /// Look for a newer release on GitHub at launch and every few hours. Only the release list is
    /// fetched; nothing about you or your Mac is sent.
    public var checkAutomatically: Bool = true
    /// The GitHub repository releases come from, "owner/name".
    public var repository: String = "kadeclifton/notetaker"

    public init() {}
}

public struct FeedbackConfig: Codable, Equatable, Sendable {
    public var sounds: Bool = true
    public var pill: Bool = true

    public init() {}
}

// MARK: - Loading

public enum ConfigError: Error, CustomStringConvertible {
    case invalid(path: String, underlying: Error)
    case notAnObject

    public var description: String {
        switch self {
        case let .invalid(path, underlying):
            return "Could not read \(path): \(underlying)"
        case .notAnObject:
            return "The settings file must contain a JSON object ({ ... })."
        }
    }
}

extension Config {
    /// Parses the settings file. `//` and `/* */` comments and trailing commas are allowed.
    /// Any key missing from the file keeps its default: the file is merged over the defaults before decoding.
    public static func parse(_ text: String) throws -> Config {
        let json = JSONC.strip(text)
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Config() }
        guard let user = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw ConfigError.notAnObject
        }
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Config())) as? [String: Any] ?? [:]
        let merged = try JSONSerialization.data(withJSONObject: deepMerge(defaults, user))
        return try JSONDecoder().decode(Config.self, from: merged)
    }

    static func deepMerge(_ base: [String: Any], _ overlay: [String: Any]) -> [String: Any] {
        base.merging(overlay) { old, new in
            if let old = old as? [String: Any], let new = new as? [String: Any] { return deepMerge(old, new) }
            return new
        }
    }

    /// Loads the settings file, writing the documented default one first if it does not exist.
    public static func loadOrCreate(at url: URL) throws -> Config {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(defaultFileContents.utf8).write(to: url, options: .atomic)
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        do {
            return try parse(text)
        } catch {
            throw ConfigError.invalid(path: url.path, underlying: error)
        }
    }

    /// The settings file written on first launch. Must parse to `Config()`.
    public static let defaultFileContents = """
    // Murmur settings. Edit, then choose "Reload Settings" from the menu bar icon.
    // Comments and trailing commas are fine. Delete a key to get its default back.
    {
      // Hold to talk; double-tap for hands-free, tap again to stop. Esc cancels.
      // Modifier keys on their own: "fn", "rightOption", "rightCommand", "rightControl",
      //   "rightShift", "leftOption", "leftCommand", "leftControl", "leftShift".
      // Or a shortcut: "ctrl+option+space", "cmd+shift+d", "f13".
      "hotkey": "fn",

      // What each way of holding the hotkey does: "dictate" (exactly what you said, fastest),
      // "clean" (filler words out, punctuation fixed) or "compose" (a rambling draft turned into
      // finished writing, shown in a preview first). Hold ⌃ / ⌃⌥ with the hotkey at any point.
      "modes": {
        "hotkey": "dictate",
        "withControl": "clean",
        "withControlOption": "compose"
      },

      "transcription": {
        // "auto": Groq or OpenAI if a key is in .env, otherwise local whisper.cpp.
        // "local": always whisper.cpp, fully offline. Or force "groq" / "openai".
        "engine": "auto",
        // ISO code like "en" or "de", or "auto" to detect.
        "language": "en",
        // Names and jargon Whisper keeps getting wrong.
        "vocabulary": [],
        "whisperCpp": {
          // Empty: find whisper-cli in /opt/homebrew/bin, /usr/local/bin, and friends.
          "binary": "",
          // scripts/download-model.sh small.en (or medium.en) puts it here.
          // Relative paths are inside this settings folder.
          "model": "models/ggml-small.en.bin",
          // 0: pick automatically.
          "threads": 0,
          // Keep the model loaded in a background whisper-server so dictation starts
          // transcribing immediately. false: run whisper-cli fresh each time (slower, less memory).
          "keepModelLoaded": true,
          "serverPort": 47813,
          // Free the model's memory after this many idle minutes (it reloads when you press the
          // hotkey, while you talk). 0: keep it loaded as long as Murmur runs.
          "unloadAfterMinutes": 30
        },
        "groqModel": "whisper-large-v3-turbo",
        "openaiModel": "whisper-1",
        "timeoutSeconds": 60
      },

      "cleanup": {
        // "clean" mode: removes filler words and fixes punctuation. If it fails or no model is
        // available, the raw transcript is inserted instead. false: "clean" works like "dictate".
        "enabled": true,
        // "auto" (first of Groq, OpenAI, Anthropic with a key), "groq", "openai",
        // "anthropic", or "custom" for any OpenAI-compatible server in baseURL.
        "provider": "auto",
        // Empty: the provider's default model.
        "model": "",
        // For "custom", e.g. Ollama at "http://localhost:11434/v1" keeps everything offline.
        "baseURL": "",
        "timeoutSeconds": 10,
        // Added to the prompt, e.g. "Use British spelling."
        "extraInstructions": ""
      },

      "insertion": {
        // "paste" (clipboard + Cmd-V) or "type" (simulated keystrokes).
        "method": "paste",
        // false: the transcript stays on the clipboard so you can paste it again.
        // true: your previous clipboard is put back after inserting.
        "restoreClipboard": false,
        "restoreDelayMs": 500
      },

      "handsFree": {
        // Stop recording automatically after this many minutes.
        "maxMinutes": 5,
        // "transcribe" or "discard" what was recorded when the limit hits.
        "onTimeLimit": "transcribe"
      },

      "timing": {
        "tapMaxMs": 250,
        "doubleTapWindowMs": 350,
        "chordGuardMs": 400
      },

      "feedback": {
        "sounds": true,
        "pill": true
      },

      // Updates: Murmur checks GitHub for a newer release and offers it in the menu. Installing
      // only goes ahead if the download is signed by the same developer as this copy.
      "updates": {
        "checkAutomatically": true,
        "repository": "kadeclifton/notetaker"
      },

      // Meeting Notes (menu bar → Start Meeting Notes): records your mic and the call's audio,
      // transcribes as it goes, and writes a summary when you stop.
      "meeting": {
        "folder": "~/Documents/Murmur Meetings",
        // Also record what others say (the audio playing on this Mac). Needs the
        // Screen & System Audio Recording permission. false: your microphone only.
        "captureSystemAudio": true,
        "chunkSeconds": 30,
        "maxHours": 4,
        "summarize": true,
        // Same choices as cleanup.provider. "local" = Ollama or LM Studio on this Mac.
        "summaryProvider": "auto",
        "summaryModel": "",
        "summaryTimeoutSeconds": 600
      },

      // Compose (hotkey + ⌃⌥): say it however it comes out; get it back thought through.
      "compose": {
        // Same choices as cleanup.provider. On "auto" with no API key, the biggest local model
        // that fits this Mac's memory. Set "model" to pin one, e.g. "qwen3:30b".
        "provider": "auto",
        "model": "",
        // "auto" (from what you said, then the app), "message", "email", "bullets",
        // "document" or "prompt". Say "as bullet points" or "make it an email" to pick one.
        "defaultStyle": "auto",
        "maxMinutes": 15,
        "timeoutSeconds": 180,
        // Every piece is kept here with what you said. Browse it from the menu: Compose Library.
        "folder": "~/Documents/Murmur Library",
        "extraInstructions": ""
      }
    }

    """
}

/// Minimal JSON-with-comments support.
enum JSONC {
    /// Removes `//` and `/* */` comments and trailing commas, leaving string contents alone.
    static func strip(_ input: String) -> String {
        let chars = Array(input.unicodeScalars)
        var out = String.UnicodeScalarView()
        var i = 0
        var inString = false
        while i < chars.count {
            let ch = chars[i]
            let next: Unicode.Scalar? = i + 1 < chars.count ? chars[i + 1] : nil
            if inString {
                out.append(ch)
                if ch == "\\", let next {
                    out.append(next)
                    i += 2
                    continue
                }
                if ch == "\"" { inString = false }
                i += 1
            } else if ch == "\"" {
                inString = true
                out.append(ch)
                i += 1
            } else if ch == "/", next == "/" {
                while i < chars.count, chars[i] != "\n" { i += 1 }
            } else if ch == "/", next == "*" {
                i += 2
                while i < chars.count, !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") { i += 1 }
                i += 2
            } else if ch == "," {
                // Drop the comma if the next significant character closes an object or array.
                var j = i + 1
                var trailing = false
                while j < chars.count {
                    let c = chars[j]
                    if c == " " || c == "\t" || c == "\n" || c == "\r" { j += 1; continue }
                    if c == "/", j + 1 < chars.count, chars[j + 1] == "/" {
                        while j < chars.count, chars[j] != "\n" { j += 1 }
                        continue
                    }
                    if c == "/", j + 1 < chars.count, chars[j + 1] == "*" {
                        j += 2
                        while j < chars.count, !(chars[j] == "*" && j + 1 < chars.count && chars[j + 1] == "/") { j += 1 }
                        j += 2
                        continue
                    }
                    trailing = (c == "}" || c == "]")
                    break
                }
                if !trailing { out.append(ch) }
                i += 1
            } else {
                out.append(ch)
                i += 1
            }
        }
        return String(out)
    }
}

// MARK: - Locations

public enum AppPaths {
    /// `~/.config/murmur`, or `$MURMUR_HOME` if set.
    public static var directory: URL {
        if let custom = ProcessInfo.processInfo.environment["MURMUR_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: expandTilde(custom), isDirectory: true)
        }
        return URL(fileURLWithPath: expandTilde("~/.config/murmur"), isDirectory: true)
    }

    public static var configFile: URL { directory.appendingPathComponent("config.json") }
    public static var envFile: URL { directory.appendingPathComponent(".env") }

    /// Expands `~`, and treats relative paths as relative to `directory`.
    public static func resolve(_ path: String) -> String {
        let expanded = expandTilde(path)
        return expanded.hasPrefix("/") ? expanded : directory.appendingPathComponent(expanded).path
    }

    public static func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst()
    }
}
