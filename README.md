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
- **Meeting Notes.** Start it from the menu bar before a call. Murmur records your mic ("Me") and the
  call's audio ("Others"), transcribes as it goes, and when you stop writes a Markdown file with a
  summary, decisions, action items and the full transcript. Works with Zoom, Meet, Teams, FaceTime,
  anything that plays through your Mac.
- **Local models, no keys needed.** Murmur finds Ollama or LM Studio running on your Mac and uses it for
  cleanup and meeting summaries.
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

# One-time: a signing certificate so permissions survive rebuilds (asks for your password)
scripts/setup-signing.sh

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
| **Screen & System Audio Recording** | System Settings → Privacy & Security → Screen & System Audio Recording | Meeting Notes only: record the call's audio (what the other people say). macOS asks the first time you start Meeting Notes. Murmur records audio only; it never saves the screen. Not needed if `meeting.captureSystemAudio` is off. |

After granting **Input Monitoring** or **Accessibility**, quit and reopen Murmur. macOS often
only applies these to a freshly started process.

### The fn / Globe key

If the hotkey is `fn` (the default), stop macOS from also reacting to it:
System Settings → Keyboard → **Press 🌐 key to: Do Nothing**. Also make sure
Keyboard → Dictation's shortcut isn't set to a fn press.

### Keep permissions across rebuilds (recommended)

macOS ties these permissions to the app's code signature. Without a signing certificate each build
gets a new signature, so after a rebuild System Settings still shows Murmur switched on but the
switch no longer applies (the menu keeps showing ⚠️ Grant…). Fix it once:

```sh
scripts/setup-signing.sh        # creates a "Murmur Dev" certificate; asks for your password once
scripts/build-app.sh --install  # now signed with it
```

Grant the permissions one last time; later rebuilds keep them. The certificate stays on your Mac, can
only sign code, and can be deleted in Keychain Access. If macOS asks whether `codesign` may use the key
during a build, choose **Always Allow**.

Without the certificate, `build-app.sh --install` clears Murmur's stale entries each time so macOS asks
again cleanly. To do that by hand:

```sh
tccutil reset Accessibility com.github.kadeclifton.murmur
tccutil reset ListenEvent com.github.kadeclifton.murmur
tccutil reset ScreenCapture com.github.kadeclifton.murmur
```

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

**Speed.** With the local model, Murmur keeps `whisper-server` (part of `brew install whisper-cpp`)
running in the background with the model loaded, so a dictation only waits for the transcription
itself, not a model load. The very first transcription after installing is still slow: macOS compiles
Whisper's GPU code once. Set `whisperCpp.keepModelLoaded` to `false` to go back to running
`whisper-cli` each time (uses less memory, slower).

## Meeting Notes

1. Menu bar icon → **Start Meeting Notes** (⌘M while the menu is open). The icon turns into ⏺ with a timer.
2. Have your meeting. Dictation still works at the same time.
3. Menu bar icon → **Stop Meeting Notes**. Murmur transcribes the last bit, writes the summary and opens
   the notes, saved as `~/Documents/Murmur Meetings/2026-09-23 1530 Meeting.md`.

What's in the file:

- **Summary, Decisions, Action items, Open questions**, written by your local model (or an API model,
  see `meeting.summaryProvider`).
- **Transcript**, with timestamps and who spoke: **Me** is your microphone and **Others** is the call's
  audio. Murmur can't tell the other people apart, but the summary uses names when people say them.

The transcript is written to the file every ~30 seconds while the meeting runs, so a crash or a quit
keeps everything up to that point. Quitting mid-meeting saves the transcript without a summary.

**Headphones help.** Without them your mic also hears the call. Murmur drops lines from "Me" that
repeat what "Others" said at the same moment, but headphones give the cleanest transcript.

**Consent.** Recording people may require their permission where you or they live. Tell people
you're taking notes.

## Local models (no API keys)

Murmur looks for [Ollama](https://ollama.com) (port 11434) and [LM Studio](https://lmstudio.ai)'s
local server (port 1234) on launch and whenever you open the menu. The menu shows what it found,
e.g. `Local models (Ollama): llama3.2:3b, qwen3:8b`.

Cleanup runs on every dictation, so it only picks a **small general model** (about 8B parameters or
less, not a code model), smallest first: Qwen 3, Qwen 2.5, Llama 3.2, Llama 3.1, Gemma, Mistral, Phi.
If you only have big or code models (say `qwen3-coder:30b`), cleanup stays off and dictation stays
fast. Meeting summaries run once per meeting, so they use the most capable model you have, big ones
included. The menu's "Last dictation" line shows how long transcription and cleanup took.

Not sure what you have installed? In Terminal:

```sh
ollama list                  # Ollama
ls ~/.lmstudio/models        # LM Studio
```

With no API keys in `.env`, `"provider": "auto"` already uses the local model for cleanup and
meeting summaries. To use it even when you have keys, set `"provider": "local"` under `cleanup`
and/or `"summaryProvider": "local"` under `meeting`. Set `"model"` / `"summaryModel"` to pick a
specific one, e.g. `"qwen3:8b"`.

For LM Studio, start its server: Developer tab → **Start Server**, with a model loaded.

Rough guide on Apple Silicon: a 3–4B model (`ollama pull qwen3:4b` or `llama3.2:3b`) cleans up
dictation in about a second. A 14B+ model writes noticeably better meeting summaries. No Ollama yet?
`brew install ollama`, `ollama serve`, then pull a model.

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
      "model": "models/ggml-small.en.bin",   // relative to ~/.config/murmur
      "threads": 0,
      "keepModelLoaded": true,  // background whisper-server: much faster, uses memory
      "serverPort": 47813
    },
    "groqModel": "whisper-large-v3-turbo",
    "openaiModel": "whisper-1",
    "timeoutSeconds": 60
  },

  "cleanup": {
    "enabled": true,
    "provider": "auto",      // "auto" | "local" | "groq" | "openai" | "anthropic" | "custom"
    "model": "",             // empty: picked for you (see Local models) or the provider's default
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
  "feedback": { "sounds": true, "pill": true },

  "meeting": {
    "folder": "~/Documents/Murmur Meetings",
    "captureSystemAudio": true, // false: your microphone only
    "chunkSeconds": 30,
    "maxHours": 4,
    "summarize": true,
    "summaryProvider": "auto",  // same choices as cleanup.provider
    "summaryModel": "",
    "summaryTimeoutSeconds": 600
  }
}
```

**`engine: "auto"`** uses Groq if `GROQ_API_KEY` is set, then OpenAI if `OPENAI_API_KEY` is set,
otherwise local whisper.cpp. Set `"local"` to keep audio on your Mac even when you have keys
(for example, to use a key only for cleanup).

**`cleanup.provider: "auto"`** picks the first of Groq, OpenAI, Anthropic that has a key, then a local
Ollama or LM Studio. With none of those, cleanup is skipped and the raw transcript is inserted.
`"custom"` is for any other OpenAI-compatible server: set `"baseURL"` and `"model"`.

**Models.** `small.en` is quick on Apple Silicon and good for English. `medium.en` is more accurate
and roughly 2–3× slower. For other languages use `small` or `medium` and set `"language"`.

### Fully offline setup

```jsonc
"transcription": { "engine": "local" },
"cleanup": { "provider": "local" },          // Ollama or LM Studio; or "enabled": false
"meeting": { "summaryProvider": "local" }
```

## How it works

```
hotkey (CGEventTap) ─► state machine ─► AVAudioEngine @16 kHz ─► WAV
                                                          │
         whisper-server (local, model kept loaded)  or  Groq/OpenAI /audio/transcriptions
                                                          │
                            LLM cleanup (falls back to the raw text on failure)
                                                          │
                                   pasteboard + Cmd-V  or  keystrokes
```

- `Sources/MurmurCore`: platform-independent logic: config, `.env`, hotkey parsing, the
  hold / double-tap / hands-free / Esc state machine, WAV encoding, the Whisper and LLM clients,
  and the pipeline. Builds and tests on Linux as well.
- `Sources/Murmur`: the macOS app: event tap, microphone, text insertion, pill, menu bar,
  permissions, launch at login, and Meeting Notes (ScreenCaptureKit for the call's audio).

Meeting Notes runs the mic and the call's audio side by side: each is cut into ~30 s pieces at
pauses, transcribed with timestamps, merged into one transcript, then summarized. Long meetings are
summarized part by part first, so they fit a local model's context window.

## Development

```sh
swift build
swift test                 # MurmurCore tests; also run on Linux in CI
swift run Murmur           # unbundled: permissions go to your terminal app, no launch at login
scripts/build-app.sh       # proper .app in build/
```

Logs go to the unified log: `log stream --predicate 'process == "Murmur"'`.

## Troubleshooting

- **The menu keeps saying Grant… although Settings shows it on.** Those switches belong to an older
  build. See "Keep permissions across rebuilds" above.
- **Nothing happens when I hold fn.** Check Input Monitoring, then quit and reopen Murmur. Check that
  the 🌐 key is set to "Do Nothing". Try `"hotkey": "rightOption"` to rule out the fn key.
- **The pill shows but no text appears.** Grant Accessibility and restart Murmur. The transcript is
  also on the clipboard; press Cmd-V yourself.
- **"whisper-cli not found".** `brew install whisper-cpp`, or set `transcription.whisperCpp.binary`.
- **"Whisper model not found".** `scripts/download-model.sh small.en`.
- **Nothing is inserted into a password field.** macOS blocks synthetic input into secure fields, by design.
- **Meeting notes only have "Me".** Grant Screen & System Audio Recording, then quit and reopen Murmur.
  The notes file says so at the top when call audio wasn't recorded.
- **"No summary: no language model was found".** Start Ollama (`ollama serve`) or LM Studio's server,
  or add an API key. The menu's "Meeting summaries" line shows what will be used.
- **whisper-server problems.** Its log is `~/.config/murmur/whisper-server.log`. Set
  `whisperCpp.keepModelLoaded` to `false` to fall back to `whisper-cli`.

## License

MIT
