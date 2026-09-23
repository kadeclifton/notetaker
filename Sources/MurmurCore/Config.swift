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
    /// Groq, then OpenAI, then Anthropic, whichever has a key. No key: cleanup is skipped.
    case auto
    case groq
    case openai
    case anthropic
    /// Any OpenAI-compatible chat endpoint set in `cleanup.baseURL` (Ollama, LM Studio, llama.cpp server).
    case custom
}

public enum InsertionMethod: String, Codable, Sendable, CaseIterable {
    /// Put the text on the pasteboard and send Cmd-V. Fast, works almost everywhere.
    case paste
    /// Synthesize keystrokes. Slower, but never touches the pasteboard for insertion.
    case type
}

public struct Config: Equatable, Sendable {
    /// Key to hold for push-to-talk; double-tap it for hands-free. See `HotkeySpec`.
    public var hotkey: String = "fn"
    public var transcription = TranscriptionConfig()
    public var cleanup = CleanupConfig()
    public var insertion = InsertionConfig()
    public var handsFree = HandsFreeConfig()
    public var timing = TimingConfig()
    public var feedback = FeedbackConfig()

    public init() {}
}

public struct TranscriptionConfig: Equatable, Sendable {
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

public struct WhisperCppConfig: Equatable, Sendable {
    /// Path to `whisper-cli`. Empty: look in Homebrew's and the usual install locations.
    public var binary: String = ""
    public var model: String = "~/.config/murmur/models/ggml-small.en.bin"
    /// 0 picks a sensible count for this machine.
    public var threads: Int = 0

    public init() {}
}

public struct CleanupConfig: Equatable, Sendable {
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

public struct InsertionConfig: Equatable, Sendable {
    public var method: InsertionMethod = .paste
    /// false: the transcript stays on the clipboard so you can paste it again.
    /// true: whatever was on the clipboard before is put back after inserting.
    public var restoreClipboard: Bool = false
    /// How long to wait after Cmd-V before restoring the clipboard.
    public var restoreDelayMs: Int = 500

    public init() {}
}

public struct HandsFreeConfig: Equatable, Sendable {
    /// Any recording (hands-free, or a hold whose key-up got lost) stops after this long.
    public var maxMinutes: Double = 5
    /// What to do with a recording that hit the limit: "transcribe" or "discard".
    public var onTimeLimit: String = "transcribe"

    public init() {}
}

public struct TimingConfig: Equatable, Sendable {
    /// A press shorter than this is a tap, not a hold.
    public var tapMaxMs: Int = 250
    /// A second press within this long after a tap starts hands-free.
    public var doubleTapWindowMs: Int = 350
    /// With a modifier-only hotkey (like fn), another key pressed this soon after it
    /// means you were typing a shortcut such as fn+arrow, so the recording is dropped.
    public var chordGuardMs: Int = 400

    public init() {}
}

public struct FeedbackConfig: Equatable, Sendable {
    public var sounds: Bool = true
    public var pill: Bool = true

    public init() {}
}

// MARK: - Decoding with defaults

// Every key is optional in the settings file; anything missing keeps its default.

extension Config: Codable {
    enum CodingKeys: String, CodingKey {
        case hotkey, transcription, cleanup, insertion, handsFree, timing, feedback
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = Config()
        d.hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        d.transcription = try c.decodeIfPresent(TranscriptionConfig.self, forKey: .transcription) ?? d.transcription
        d.cleanup = try c.decodeIfPresent(CleanupConfig.self, forKey: .cleanup) ?? d.cleanup
        d.insertion = try c.decodeIfPresent(InsertionConfig.self, forKey: .insertion) ?? d.insertion
        d.handsFree = try c.decodeIfPresent(HandsFreeConfig.self, forKey: .handsFree) ?? d.handsFree
        d.timing = try c.decodeIfPresent(TimingConfig.self, forKey: .timing) ?? d.timing
        d.feedback = try c.decodeIfPresent(FeedbackConfig.self, forKey: .feedback) ?? d.feedback
        self = d
    }
}

extension TranscriptionConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case engine, language, vocabulary, whisperCpp, groqModel, openaiModel, timeoutSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = TranscriptionConfig()
        d.engine = try c.decodeIfPresent(TranscriptionEngine.self, forKey: .engine) ?? d.engine
        d.language = try c.decodeIfPresent(String.self, forKey: .language) ?? d.language
        d.vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        d.whisperCpp = try c.decodeIfPresent(WhisperCppConfig.self, forKey: .whisperCpp) ?? d.whisperCpp
        d.groqModel = try c.decodeIfPresent(String.self, forKey: .groqModel) ?? d.groqModel
        d.openaiModel = try c.decodeIfPresent(String.self, forKey: .openaiModel) ?? d.openaiModel
        d.timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        self = d
    }
}

extension WhisperCppConfig: Codable {
    enum CodingKeys: String, CodingKey { case binary, model, threads }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = WhisperCppConfig()
        d.binary = try c.decodeIfPresent(String.self, forKey: .binary) ?? d.binary
        d.model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        d.threads = try c.decodeIfPresent(Int.self, forKey: .threads) ?? d.threads
        self = d
    }
}

extension CleanupConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case enabled, provider, model, baseURL, timeoutSeconds, extraInstructions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = CleanupConfig()
        d.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        d.provider = try c.decodeIfPresent(CleanupProvider.self, forKey: .provider) ?? d.provider
        d.model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        d.baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        d.timeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .timeoutSeconds) ?? d.timeoutSeconds
        d.extraInstructions = try c.decodeIfPresent(String.self, forKey: .extraInstructions) ?? d.extraInstructions
        self = d
    }
}

extension InsertionConfig: Codable {
    enum CodingKeys: String, CodingKey { case method, restoreClipboard, restoreDelayMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = InsertionConfig()
        d.method = try c.decodeIfPresent(InsertionMethod.self, forKey: .method) ?? d.method
        d.restoreClipboard = try c.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? d.restoreClipboard
        d.restoreDelayMs = try c.decodeIfPresent(Int.self, forKey: .restoreDelayMs) ?? d.restoreDelayMs
        self = d
    }
}

extension HandsFreeConfig: Codable {
    enum CodingKeys: String, CodingKey { case maxMinutes, onTimeLimit }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = HandsFreeConfig()
        d.maxMinutes = try c.decodeIfPresent(Double.self, forKey: .maxMinutes) ?? d.maxMinutes
        d.onTimeLimit = try c.decodeIfPresent(String.self, forKey: .onTimeLimit) ?? d.onTimeLimit
        self = d
    }
}

extension TimingConfig: Codable {
    enum CodingKeys: String, CodingKey { case tapMaxMs, doubleTapWindowMs, chordGuardMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = TimingConfig()
        d.tapMaxMs = try c.decodeIfPresent(Int.self, forKey: .tapMaxMs) ?? d.tapMaxMs
        d.doubleTapWindowMs = try c.decodeIfPresent(Int.self, forKey: .doubleTapWindowMs) ?? d.doubleTapWindowMs
        d.chordGuardMs = try c.decodeIfPresent(Int.self, forKey: .chordGuardMs) ?? d.chordGuardMs
        self = d
    }
}

extension FeedbackConfig: Codable {
    enum CodingKeys: String, CodingKey { case sounds, pill }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = FeedbackConfig()
        d.sounds = try c.decodeIfPresent(Bool.self, forKey: .sounds) ?? d.sounds
        d.pill = try c.decodeIfPresent(Bool.self, forKey: .pill) ?? d.pill
        self = d
    }
}

// MARK: - Loading

public enum ConfigError: Error, CustomStringConvertible {
    case invalid(path: String, underlying: Error)

    public var description: String {
        switch self {
        case let .invalid(path, underlying):
            return "Could not read \(path): \(underlying)"
        }
    }
}

extension Config {
    /// Parses the settings file. `//` and `/* */` comments and trailing commas are allowed.
    public static func parse(_ text: String) throws -> Config {
        let json = JSONC.strip(text)
        if json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return Config() }
        return try JSONDecoder().decode(Config.self, from: Data(json.utf8))
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
          "model": "~/.config/murmur/models/ggml-small.en.bin",
          // 0: pick automatically.
          "threads": 0
        },
        "groqModel": "whisper-large-v3-turbo",
        "openaiModel": "whisper-1",
        "timeoutSeconds": 60
      },

      "cleanup": {
        // Removes filler words and fixes punctuation. If it fails or no key is set,
        // the raw transcript is inserted instead.
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

    public static func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + path.dropFirst()
    }
}
