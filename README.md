# Murmur

System-wide dictation for macOS, in the spirit of Wispr Flow. Hold a key, talk, let go, and
the text appears at your cursor in whatever app has focus.

- **Three ways to talk.** Hold `fn` alone for plain dictation: exactly what you said, as fast as
  possible. Add `⌃` (fn⌃) to clean it up: filler words out, punctuation fixed. Add `⌃⌥` (fn⌃⌥) to
  **Compose**: ramble it out, and a bigger model turns it into finished writing (a message, an email,
  bullets, a doc, an AI prompt) in a preview you can insert, copy, restyle or edit.
- **Library.** Everything Compose writes is kept with what you said, and every meeting's notes,
  as Markdown files you can browse and search from the menu bar.
- **Snippets and "scratch that".** Say "my address" and saved text goes in. Say "scratch that" to
  undo the last dictation.
- **Hands-free.** Double-tap the hotkey and it keeps recording with nothing held. Tap once more to finish.
  It stops by itself after 5 minutes, so a forgotten session can't record all afternoon.
- **Esc cancels.** During recording it drops the audio. During transcription it kills the job
  (the whisper.cpp process or the HTTP request). Esc is only observed, never swallowed, so it still
  reaches the app you are typing in.
- **Local or cloud speech-to-text.** whisper.cpp on your Mac (offline, shipped inside the app, built
  with Metal and Core ML so it can use the Neural Engine), or the Groq / OpenAI Whisper API when a
  key is in `.env`. One config flag picks.
- **LLM cleanup.** A short prompt removes filler words, fixes punctuation, and keeps casing the way
  you would type it. Groq, OpenAI, Anthropic, or any OpenAI-compatible local server (Ollama, LM Studio).
  If cleanup fails or no key is set, the raw transcript is inserted, so nothing is lost.
- **Inserts anywhere.** Pasteboard + Cmd-V (default) or simulated keystrokes. The transcript stays on
  the clipboard so you can paste it again; or set a flag to restore your previous clipboard.
- **A tiny pill** just under the menu bar shows when it's live, which mode you're in, the input
  level, and a countdown near the hands-free limit. Drag it anywhere (it remembers), or pick a spot
  in Settings.
- **Meeting Notes.** Start it from the menu bar before a call. Murmur records your mic ("Me") and the
  call's audio ("Others"), transcribes as it goes, and when you stop writes a Markdown file with a
  summary, decisions, action items and the full transcript. Works with Zoom, Meet, Teams, FaceTime,
  anything that plays through your Mac. When a call starts, Murmur offers to take notes, and a live
  transcript window follows along.
- **Local models, no keys needed.** Murmur finds Ollama or LM Studio running on your Mac and uses it for
  cleanup, Compose and meeting summaries, sized to what your Mac can run.
- **Menu bar** toggle for on/off, launch at login, and shortcuts to the settings file and `.env`.
- **No accounts, no telemetry.** Nothing leaves your Mac unless you configure a cloud API.
  With the local model and cleanup off (or a local LLM), it works fully offline.

**Just want to use it?** Download the latest release and follow [docs/INSTALL.md](docs/INSTALL.md):
no Xcode needed, a setup window walks you through the rest.

## Requirements

- macOS 14 (Sonoma) or later
- Xcode or the Xcode Command Line Tools (Swift 5.9+) to build
- For local transcription: a model (below). Release builds include whisper.cpp; to build it into
  your own build, `brew install cmake` and run `scripts/build-whisper.sh` (or `brew install whisper-cpp`
  and Murmur uses Homebrew's)

## Install

```sh
git clone https://github.com/kadeclifton/notetaker.git murmur && cd murmur

# Local speech-to-text (skip if you'll only use Groq/OpenAI): whisper.cpp with Core ML, built into the app
brew install cmake && scripts/build-whisper.sh
scripts/download-model.sh small.en      # 466 MB. Or: medium.en (1.5 GB, more accurate)

# One-time: a signing certificate so permissions survive rebuilds (asks for your password)
scripts/setup-signing.sh

# Build Murmur.app and install it to /Applications (or ~/Applications)
scripts/build-app.sh --install
```

Murmur appears in the menu bar as its wave: the loudness of the word "murmur", in 13 bars. There is no Dock icon.

Optional: add API keys. Choose **More → Open API Keys (.env)** from the menu (it
creates `~/.config/murmur/.env`), fill in what you have, then **More → Reload Settings**:

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

## The menu

Click the wave in the menu bar:

- **Status line**: "Ready", or **⚠️ Finish Setup…** when something needs fixing (click it).
- **Dictation** (⌘E): on/off.
- **Start Meeting Notes** (⌘M); while recording, **Live Transcript…**.
- **Library…** (⌘L): everything Compose has written, and every meeting's notes.
- **Recent**: **Undo Last Dictation**, then the last 10 dictations and composes, click to copy again
  (kept in memory only).
- **Snippets**: click one to type it where you are, **Add Snippet…**, and **Edit Snippets…**.
- **Vocabulary**: add or remove the names and jargon passed to Whisper (`transcription.vocabulary`).
- **More**: setup window, how-to, pill position, launch at login, the meeting notes and library
  folders, the settings and API key files, **Check for Updates…** and **Copy Diagnostics**.
- **Settings…** (⌘,): hotkey picker; **Speech** (microphone, speech model and how long the last
  dictation took, Neural Engine, vocabulary); **Writing** (whether plain fn cleans up too, which
  models clean up and compose, how long Ollama keeps the cleanup model loaded, and the Compose model:
  Automatic picks the best one that fits your Mac); snippets; meeting options; version and diagnostics.
  Picking a specific microphone helps in clamshell mode with a webcam or display mic; a silent
  recording names the mic it listened to, and quiet mics are boosted (up to +26 dB).
- **An update is available · Restart to Update** appears just above Quit once a newer release has
  downloaded in the background.

## Using it

| Do this | Result |
| --- | --- |
| Hold fn, talk, release | Insert exactly what you said (no language model, fastest) |
| Hold fn⌃, talk, release | Insert it cleaned up: no "um"s, fixed punctuation, your words |
| Hold fn⌃⌥, talk, release | Compose: a preview panel writes it up; ⏎ inserts, Esc closes |
| Double-tap the hotkey | Hands-free recording starts (pill shows 🔒 Hands-free) |
| Tap the hotkey during hands-free | Stop, transcribe, insert |
| Esc while recording | Discard the recording |
| Esc while the pill says "Transcribing" | Cancel the transcription; nothing is inserted |
| A single quick tap | Nothing (it's ignored) |
| fn + another key within 0.4 s (e.g. fn+←) | Treated as a normal shortcut; the recording is dropped |

⌃ and ⌥ count whenever they are held with fn during the recording, so you can start talking and add
them after. The pill shows the mode (**Clean Up** or **Compose**). Double-tapping works in every mode;
for hands-free Compose, hold ⌃⌥ during either tap. Compose recordings may run 15 minutes
(`compose.maxMinutes`). The modes apply to a modifier hotkey like fn; a shortcut hotkey such as
`ctrl+option+space` does whatever `modes.hotkey` says.

## Compose

Hold **fn⌃⌥** and talk it through however it comes out: false starts, "wait, no", tangents. Let go,
and a panel opens and writes it as you watch. It keeps every fact, name and number, drops the
thinking-out-loud, puts it in order, and keeps your voice.

The **style** adapts:

1. **Say it**: "…as bullet points", "make this an email to Sam", "write it as a prompt".
2. **Pick it** in the panel: Auto, Message, Email, Bullets, Document, AI Prompt. It rewrites at once.
3. **From the app**: Slack or Messages → message, Mail or Gmail → email, Notes or Notion → document,
   ChatGPT, Claude, Cursor or Terminal → AI prompt. In a browser it goes by the page title.
4. Otherwise **Auto** picks the form that fits the content. `compose.defaultStyle` changes the fallback.

In the panel: **⏎ Insert** puts it where your cursor was, **Copy**, **Try Again** for another take,
**Edit** to change it first, and **What I said** shows the transcript. Hold fn to dictate into the
editor too.

**Compose Library** (⌘L) keeps every piece with what you said, newest first, with search. It saves
the moment the transcript is ready, so a ramble is never lost even if you close the panel. Edit a
piece there and it is saved. The pieces are plain Markdown files in `~/Documents/Murmur Library`
(`compose.folder`), so Spotlight finds them too.

**Which model.** Compose only runs when you ask, so it uses the most capable local model that fits
in your Mac's memory (up to 60% of it), not the small cleanup model. With 32 GB or more that is
`qwen3:30b` (a fast mixture-of-experts model, about 19 GB); 24 GB → `qwen3:14b`; 16 GB →
`qwen3:8b`; 8 GB → `qwen3:4b`. Settings… → Writing suggests the one to pull and its **Compose
model** picker overrides the choice (it sets `compose.model`). Murmur starts loading the model the moment
you press ⌃⌥, while you are still talking. With a Groq, OpenAI or Anthropic key, `"provider": "auto"`
uses that instead; set `"provider": "local"` under `compose` to keep it on your Mac.

When a control that can't take text has focus (a Finder list, a button), Murmur doesn't paste into
it: the text stays on the clipboard and the pill says so. Anything uncertain, including browsers
and Electron apps that report no focused element, gets the paste as usual. The pill shows **Transcribing**, then
**Cleaning up**, and the menu bar wave pulses while either runs.

**Memory.** whisper-server stops after 30 minutes without dictation
(`whisperCpp.unloadAfterMinutes`, 0 to keep it) and starts again the moment you press the hotkey,
while you talk. Compose's automatic model choice skips "thinking" builds (named so, or seen
reasoning regardless) when another model fits, since they spend 20 to 40 seconds reasoning first.

Silent recordings are dropped before transcription, since Whisper tends to invent text
("Thanks for watching!") for silence.

**Speed.** With the local model, Murmur keeps `whisper-server` (shipped inside Murmur.app, or
Homebrew's) running in the background with the model loaded, so a dictation only waits for the transcription
itself, not a model load. The very first transcription after installing is still slow: macOS compiles
Whisper's GPU code once. Set `whisperCpp.keepModelLoaded` to `false` to go back to running
`whisper-cli` each time (uses less memory, slower).

**Neural Engine.** The whisper.cpp inside Murmur is built with Core ML. Settings… → Speech → **Use
the Neural Engine** downloads the model's Core ML encoder (`ggml-<model>-encoder.mlmodelc`, next to
the model); whisper.cpp then runs the encoder on the Neural Engine and the rest on the GPU. It mostly
frees the GPU and saves battery; speed is similar to Metal on most Macs. macOS prepares the encoder
the first time it loads, which can take a few minutes for the large model. Turn it off to delete the
encoder and go back to the GPU. Homebrew's whisper.cpp is built without Core ML, so the option only
appears when Murmur uses its own.

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
included. **Settings… → Speech → Last dictation** shows how long transcription and cleanup took.

Not sure what you have installed? In Terminal:

```sh
ollama list                  # Ollama
ls ~/.lmstudio/models        # LM Studio
```

With no API keys in `.env`, `"provider": "auto"` already uses the local model for cleanup, Compose
and meeting summaries. To use it even when you have keys, set `"provider": "local"` under `cleanup`
and/or `"summaryProvider": "local"` under `meeting`. Set `"model"` / `"summaryModel"` to pick a
specific one, e.g. `"qwen3:8b"`.

For LM Studio, start its server: Developer tab → **Start Server**, with a model loaded.

**Keeping the model loaded.** Ollama unloads a model after 5 idle minutes, and the next dictation then
waits a few seconds while it loads again. When cleanup runs on Ollama, **Settings… → Writing → Keep <model>
loaded** offers with 5 minutes, 30 minutes (Murmur's default), 1 hour, 4 hours, or always. Murmur also loads
the model at launch, so the first dictation doesn't wait. A 4B model takes about 3 GB of memory while
it stays loaded. Meeting summary models are left to Ollama's normal 5 minutes.

Rough guide on Apple Silicon: a 3–4B model (`ollama pull qwen3:4b` or `llama3.2:3b`) cleans up
dictation in about a second. A 14B+ model writes noticeably better meeting summaries. No Ollama yet?
`brew install ollama`, `ollama serve`, then pull a model.

## Settings

The settings file is `~/.config/murmur/config.json` (menu → **Settings → Open Settings File**). It's
created with comments on first launch. Edit it, then choose **Settings → Reload Settings**. Any key you delete goes
back to its default. `MURMUR_HOME` moves the whole directory.

```jsonc
{
  // "fn", "rightOption", "rightCommand", "rightControl", "rightShift", "leftOption", ...
  // or a shortcut: "ctrl+option+space", "cmd+shift+d", "f13"
  "hotkey": "fn",

  // "dictate" | "clean" | "compose" for the hotkey alone, with ⌃, and with ⌃⌥
  "modes": { "hotkey": "dictate", "withControl": "clean", "withControlOption": "compose" },

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
  },

  "compose": {
    "provider": "auto",      // same choices as cleanup.provider
    "model": "",             // empty: the best local model that fits this Mac, e.g. "qwen3:30b"
    "defaultStyle": "auto",  // "auto" | "message" | "email" | "bullets" | "document" | "prompt"
    "maxMinutes": 15,
    "timeoutSeconds": 180,
    "folder": "~/Documents/Murmur Library",
    "extraInstructions": ""  // e.g. "I write in British English."
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
   fn: as is  ·  fn⌃: LLM cleanup (raw text on failure)  ·  fn⌃⌥: Compose (streamed preview)
                                                          │                        │
                                   pasteboard + Cmd-V  or  keystrokes      Compose Library (.md)
```

- `Sources/MurmurCore`: platform-independent logic: config, `.env`, hotkey parsing, the
  hold / double-tap / hands-free / Esc state machine, WAV encoding, the Whisper and LLM clients,
  and the pipeline. Builds and tests on Linux as well.
- `Sources/Murmur`: the macOS app: event tap, microphone, text insertion, pill, menu bar,
  permissions, launch at login, and Meeting Notes (ScreenCaptureKit for the call's audio).

Meeting Notes runs the mic and the call's audio side by side: each is cut into ~30 s pieces at
pauses, transcribed with timestamps, merged into one transcript, then summarized. Long meetings are
summarized part by part first, so they fit a local model's context window.

## Releases (sharing with friends)

Pushing a version tag builds Murmur on GitHub's macOS runners and publishes it as a release, with
[docs/INSTALL.md](docs/INSTALL.md) as the release notes:

```sh
git tag v0.1.0
git push origin v0.1.0
```

Each release has `Murmur-vX.dmg`, a disk image that opens as a window with the app and an
Applications folder to drag it onto (for first installs), and `Murmur-vX.zip` (used by the in-app
updater). Both are Apple Silicon, macOS 14+. `scripts/make-dmg.sh` builds the disk image locally
after `scripts/build-app.sh` (`brew install create-dmg` for the window layout;
`scripts/make-dmg-background.py` redraws its background).

**Signing and notarization.** With an Apple Developer account, releases are signed with your
Developer ID and notarized, so friends just unzip and open, and permissions survive updates. Set up
once:

1. Xcode → Settings → Accounts → your Apple ID → **Manage Certificates** → **+** → **Developer ID
   Application**.
2. Keychain Access → My Certificates → right-click it → **Export** as `.p12` with a password.
3. appleid.apple.com → Sign-In and Security → **App-Specific Passwords** → create one.
4. In the GitHub repo, Settings → Secrets and variables → Actions, add:
   `DEVELOPER_ID_P12` (`base64 -i cert.p12 | pbcopy`), `DEVELOPER_ID_P12_PASSWORD`, `APPLE_ID`,
   `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID` (developer.apple.com → Membership).

The release workflow then signs with the hardened runtime, sends the app to Apple's notary service
(a few minutes), and staples the ticket. Without the secrets, releases are ad-hoc signed and friends
need the `xattr` step in INSTALL.md. `scripts/build-app.sh` also uses a Developer ID certificate when
one is in your keychain, so local builds match releases.

For people to download it, the repository has to be public, or they need to be added as collaborators.

**Updates.** Murmur asks GitHub for the latest release shortly after launch and every six hours
(`updates.checkAutomatically`; only the public release list is fetched). When there is a newer
one, it downloads the zip in the background and checks that the new app is signed with the same
Developer ID Team as the running one, intact (`codesign --verify`) and notarized (`spctl`). The menu
then shows **Restart to Update** above Quit: one click swaps it in place and relaunches. Copies not signed with a Developer ID (local ad-hoc or
"Murmur Dev" builds) get a link to the release page instead.

**Which speech model on which Mac.** **Settings… → Speech → Speech model** switches between the three the setup
window offers, and **Last dictation** shows the time each one takes on your Mac:

| Model | Size | Best for |
| --- | --- | --- |
| Fastest (`base.en`) | 142 MB | 8 GB MacBook Airs, short messages |
| Balanced (`small.en`) | 466 MB | most Macs; the default |
| Most accurate (`large-v3-turbo-q5_0`) | 547 MB | names, jargon, accents, other languages; Pro/Max chips |

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
- **"whisper-cli not found".** A build without bundled whisper.cpp: run `scripts/build-whisper.sh`
  and rebuild, `brew install whisper-cpp`, or set `transcription.whisperCpp.binary`.
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
