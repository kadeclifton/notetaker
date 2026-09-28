# Privacy

Murmur is built to keep what you say on your Mac. There are no accounts, no analytics and no
telemetry. Nobody, including the developer, sees what you dictate or how you use the app.

## What stays on your Mac

- **Your voice.** Dictation audio is kept in memory only while it is transcribed, then discarded.
  Meeting Notes never saves audio either, only the transcript and summary.
- **What you dictate.** It goes into the app you are typing in, and stays on the clipboard unless
  you turn on `insertion.restoreClipboard`. The Recent list lives in memory and is gone when Murmur
  quits.
- **Files Murmur writes,** all readable and deletable by you:
  - `~/.config/murmur/`: settings (`config.json`), API keys (`.env`, readable only by you), speech
    models, and the speech recognizer's log.
  - `~/Documents/Murmur Library/`: what Compose wrote and what you said, one Markdown file each.
  - `~/Documents/Murmur Meetings/`: meeting transcripts and summaries.
  - A few preferences in macOS's own store (microphone choice, pill position, whether Dictation is on),
    and your dictation stats: how many words per day for the last 90 days, never the words themselves.
  - Murmur's last 20 error messages (what went wrong and when, never what you said), so Copy
    Diagnostics can include them.
- **Copy Diagnostics** puts settings, status and those recent errors on your clipboard only when you
  click it. It never includes anything you dictated or your API keys.

## What goes over the network, and only when

| When | To | What |
| --- | --- | --- |
| At launch and every 6 hours (turn off with `updates.checkAutomatically`) | GitHub | A request for the latest release number. Nothing about you or your Mac. |
| When an update is found | GitHub | The update download. |
| When you download a speech model or turn on the Neural Engine | Hugging Face | The model files. |
| Only if you add a Groq or OpenAI key | That provider | Your dictation audio, for transcription. |
| Only if you add a Groq, OpenAI or Anthropic key | That provider | The transcript, for cleanup, Compose or meeting summaries; for Edit, also the text you selected. |
| Only if you set a custom cleanup server | That server | The transcript. Plain `http://` is refused unless the server is on your Mac or home network. |

With no API keys, transcription runs on your Mac (whisper.cpp), and cleanup, Compose and summaries
use Ollama or LM Studio on your Mac, if you have them. Nothing you say leaves the machine. Each
provider's own privacy policy applies to anything you choose to send it.

## Permissions

Murmur asks macOS for the microphone (to hear you), Accessibility (to paste), Input Monitoring (to
see the hotkey) and, for Meeting Notes only, Screen & System Audio Recording (to hear the other
people on a call; it records audio, never the screen). It watches only the hotkey and Esc and logs no
keystrokes. When Murmur offers to take notes for a call, or to stop when it ends, it only checks
whether a microphone is in use and which apps are running. It never starts recording without you saying yes.

## Removing everything

**Settings… → About → Remove Murmur…** moves the app to the Trash and deletes its settings, API
keys, speech models, preferences and permissions. Your Library and meeting notes in Documents stay;
delete those two folders yourself if you want them gone too.

Questions: open an issue at https://github.com/kadeclifton/notetaker/issues.
