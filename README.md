# Murmur

System-wide dictation for macOS, in the spirit of Wispr Flow. Hold a key, talk, let go, and
the cleaned-up text appears at your cursor in whatever app has focus.

- **Hold to talk.** Hold `fn` (or a key you pick), speak, release. Murmur transcribes, cleans up and pastes.
- **Hands-free.** Double-tap the hotkey and it keeps recording with nothing held. Tap once more to finish.
  It stops by itself after 5 minutes, so a forgotten session can't record all afternoon.
- **Esc cancels.** During recording it drops the audio. During transcription it kills the job
  (the whisper.cpp process or the HTTP request). Esc is only observed, never swallowed, so it still
  reaches the app you are typing in.
- **Local or cloud speech-to-text.** whisper.cpp on your Mac (small or medium model, offline), or the
  Groq / OpenAI Whisper API when a key is in `.env`. One config flag picks.
- **LLM cleanup.** A short prompt removes filler words, fixes punctuation, and keeps casing the way
  you would type it. Groq, OpenAI, Anthropic, or any OpenAI-compatible local server (Ollama, LM Studio).
  If cleanup fails or no key is set, the raw transcript is inserted, so nothing is lost.
- **Inserts anywhere.** Pasteboard + Cmd-V (default) or simulated keystrokes. The transcript stays on
  the clipboard so you can paste it again; or set a flag to restore your previous clipboard.
- **A tiny pill** at the bottom of the screen shows when it's live, which mode you're in, the input
  level, and a countdown near the hands-free limit.
- **Menu bar** toggle for on/off, launch at login, and shortcuts to the settings file and `.env`.
- **No accounts, no telemetry.** Nothing leaves your Mac unless you configure a cloud API.
  With the local model and cleanup off (or a local LLM), it works fully offline.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode or the Xcode Command Line Tools (Swift 5.9+) to build
- For local transcription: `brew install whisper-cpp` and a model (below)

## Install

```sh
git clone https://github.com/kadeclifton/notetaker.git murmur && cd murmur

# Local speech-to-text (skip if you'll only use Groq/OpenAI)
brew install whisper-cpp
scripts/download-model.sh small.en      # 466 MB. Or: medium.en (1.5 GB, more accurate)

# Build Murmur.app and install it to /Applications (or ~/Applications)
scripts/build-app.sh --install
```

Murmur appears as a waveform icon in the menu bar. There is no Dock icon.

Optional: add API keys. Choose **Open .env (API keys)** from the menu (it creates
`~/.config/murmur/.env`), fill in what you have, then **Reload Settings**:

```sh
GROQ_API_KEY=gsk_...        # fast Whisper + cleanup
OPENAI_API_KEY=sk-...       # Whisper + cleanup
ANTHROPIC_API_KEY=sk-ant-...# cleanup only
```

See `.env.example` for the full list.

## Permissions

macOS asks for three permissions. Murmur can't work without them, and the menu shows a
⚠️ item that jumps to the right Settings pane for anything that's missing.

| Permission | Where | Why |
| --- | --- | --- |
| **Microphone** | System Settings → Privacy & Security → Microphone | Record your voice while the hotkey is held. macOS prompts on first launch. |
| **Input Monitoring** | System Settings → Privacy & Security → Input Monitoring | See the hotkey and Esc while other apps have focus. Murmur only listens for those keys; nothing is logged or stored. |
| **Accessibility** | System Settings → Privacy & Security → Accessibility | Send Cmd-V (or keystrokes) into the focused app. Also needed if your hotkey is a shortcut like `ctrl+option+space`, so Murmur can stop it from typing a space. |

After granting **Input Monitoring** or **Accessibility**, quit and reopen Murmur. macOS often
only applies these to a freshly started process.

### The fn / Globe key

If the hotkey is `fn` (the default), stop macOS from also reacting to it:
System Settings → Keyboard → **Press 🌐 key to: Do Nothing**. Also make sure
Keyboard → Dictation's shortcut isn't set to a fn press.

### Permissions keep resetting after a rebuild

macOS ties these grants to the app's code signature. `build-app.sh` signs ad-hoc by default,
and an ad-hoc signature changes on every build, so after rebuilding the entries in Settings
look enabled but no longer apply. Either remove Murmur from each list (–) and add it again, or
sign with a stable certificate:

1. Keychain Access → Certificate Assistant → Create a Certificate…
   Name: `Murmur Dev`, Identity Type: Self Signed Root, Certificate Type: **Code Signing**.
2. `CODESIGN_IDENTITY="Murmur Dev" scripts/build-app.sh --install`

Grant the permissions once more; they then survive rebuilds.

## Using it

| Do this | Result |
| --- | --- |
| Hold the hotkey, talk, release | Transcribe, clean up, insert at the cursor |
| Double-tap the hotkey | Hands-free recording starts (pill shows 🔒 Hands-free) |
| Tap the hotkey during hands-free | Stop, transcribe, insert |
| Esc while recording | Discard the recording |
| Esc while the pill says "Transcribing" | Cancel the transcription; nothing is inserted |
| A single quick tap | Nothing (it's ignored) |
| fn + another key within 0.4 s (e.g. fn+←) | Treated as a normal shortcut; the recording is dropped |

Silent recordings are dropped before transcription, since Whisper tends to invent text
("Thanks for watching!") for silence.

## Settings

The settings file is `~/.config/murmur/config.json` (menu → **Open Settings File**). It's created
with comments on first launch. Edit it, then choose **Reload Settings**. Any key you delete goes
back to its default. `MURMUR_HOME` moves the whole directory.

```jsonc
{
  // "fn", "rightOption", "rightCommand", "rightControl", "rightShift", "leftOption", ...
  // or a shortcut: "ctrl+option+space", "cmd+shift+d", "f13"
  "hotkey": "fn",

  "transcription": {
    "engine": "auto",        // "auto" | "local" | "groq" | "openai"
    "language": "en",        // or "auto"
    "vocabulary": [],        // e.g. ["Kubernetes", "Anthropic"], passed to Whisper as a hint
    "whisperCpp": {
      "binary": "",          // empty: finds whisper-cli in Homebrew's paths
      "model": "~/.config/murmur/models/ggml-small.en.bin",
      "threads": 0
    },
    "groqModel": "whisper-large-v3-turbo",
    "openaiModel": "whisper-1",
    "timeoutSeconds": 60
  },

  "cleanup": {
    "enabled": true,
    "provider": "auto",      // "auto" | "groq" | "openai" | "anthropic" | "custom"
    "model": "",             // empty: llama-3.3-70b-versatile / gpt-4.1-mini / claude-haiku-4-5
    "baseURL": "",           // for "custom", e.g. "http://localhost:11434/v1" (Ollama)
    "timeoutSeconds": 10,
    "extraInstructions": ""  // e.g. "Use British spelling."
  },

  "insertion": {
    "method": "paste",       // "paste" (Cmd-V) or "type" (keystrokes)
    "restoreClipboard": false, // true: put your previous clipboard back after inserting
    "restoreDelayMs": 500
  },

  "handsFree": { "maxMinutes": 5, "onTimeLimit": "transcribe" },  // or "discard"
  "timing": { "tapMaxMs": 250, "doubleTapWindowMs": 350, "chordGuardMs": 400 },
  "feedback": { "sounds": true, "pill": true }
}
```

**`engine: "auto"`** uses Groq if `GROQ_API_KEY` is set, then OpenAI if `OPENAI_API_KEY` is set,
otherwise local whisper.cpp. Set `"local"` to keep audio on your Mac even when you have keys
(for example, to use a key only for cleanup).

**`cleanup.provider: "auto"`** picks the first of Groq, OpenAI, Anthropic that has a key. With no
key, cleanup is skipped and the raw transcript is inserted. To clean up offline, run
[Ollama](https://ollama.com) and set `"provider": "custom"`, `"baseURL": "http://localhost:11434/v1"`,
`"model": "llama3.2"`.

**Models.** `small.en` is quick on Apple Silicon and good for English. `medium.en` is more accurate
and roughly 2–3× slower. For other languages use `small` or `medium` and set `"language"`.

### Fully offline setup

```jsonc
"transcription": { "engine": "local" },
"cleanup": { "enabled": false }   // or "provider": "custom" with a local Ollama
```

## How it works

```
hotkey (CGEventTap) ─► state machine ─► AVAudioEngine @16 kHz ─► WAV
                                                          │
                     whisper-cli (local)  or  Groq/OpenAI /audio/transcriptions
                                                          │
                            LLM cleanup (falls back to the raw text on failure)
                                                          │
                                   pasteboard + Cmd-V  or  keystrokes
```

- `Sources/MurmurCore`: platform-independent logic: config, `.env`, hotkey parsing, the
  hold / double-tap / hands-free / Esc state machine, WAV encoding, the Whisper and LLM clients,
  and the pipeline. Builds and tests on Linux as well.
- `Sources/Murmur`: the macOS app: event tap, microphone, text insertion, pill, menu bar,
  permissions, launch at login.

## Development

```sh
swift build
swift test                 # MurmurCore tests; also run on Linux in CI
swift run Murmur           # unbundled: permissions go to your terminal app, no launch at login
scripts/build-app.sh       # proper .app in build/
```

Logs go to the unified log: `log stream --predicate 'process == "Murmur"'`.

## Troubleshooting

- **Nothing happens when I hold fn.** Check Input Monitoring, then quit and reopen Murmur. Check that
  the 🌐 key is set to "Do Nothing". Try `"hotkey": "rightOption"` to rule out the fn key.
- **The pill shows but no text appears.** Grant Accessibility and restart Murmur. The transcript is
  also on the clipboard; press Cmd-V yourself.
- **"whisper-cli not found".** `brew install whisper-cpp`, or set `transcription.whisperCpp.binary`.
- **"Whisper model not found".** `scripts/download-model.sh small.en`.
- **Nothing is inserted into a password field.** macOS blocks synthetic input into secure fields, by design.

## License

MIT
