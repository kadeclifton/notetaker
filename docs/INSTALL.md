# Installing Murmur

Hold a key, talk, let go: your words appear wherever you're typing. Everything runs on your Mac.

**You need:** a Mac with Apple Silicon (M1 or newer) on macOS 14 Sonoma or later. About 5 minutes the
first time, mostly waiting on the speech model download. Nothing else to install: the speech
recognizer (whisper.cpp) comes inside Murmur, so there's no Homebrew or Terminal step.

## 1. Install Murmur

1. Download **Murmur-….dmg** from the release page (under **Assets**) and double-click it.
2. A window opens: drag the **Murmur** icon onto the **Applications** folder next to it.
3. Close the window, and eject the "Murmur" disk in Finder's sidebar (or drag it to the Trash).
4. Open Murmur from Applications (or ⌘Space, "Murmur"). macOS may ask once whether to open an app
   downloaded from the internet; click **Open**.

   Only if macOS says it "can't be opened" or "is damaged" (older, unsigned releases): run this
   in Terminal, then open it again.

   ```sh
   xattr -dr com.apple.quarantine /Applications/Murmur.app
   ```

5. Once Murmur is open, its wave icon appears in the menu bar (there is no Dock icon), and a setup window opens.

## 2. Finish setup

The setup window walks you through the rest, with a button for each step:

- **Download a speech model.** "Balanced" is right for most Macs. On an 8 GB MacBook Air, "Fastest" feels snappier.
  "Most accurate" is best with names and jargon, and slower on an Air.
- **Allow the microphone.**
- **Allow Accessibility**, so Murmur can paste into other apps.
- **Allow Input Monitoring**, so Murmur can see the fn key. Then click **Restart Murmur**.

Also set System Settings → Keyboard → **Press 🌐 key to: Do Nothing**, so macOS doesn't react to fn too.

## Using it

- **Hold fn**, talk, let go: exactly what you said is typed where your cursor is.
- **Hold fn⌃** (fn + control) to clean it up: no "um"s, proper punctuation.
- **Hold fn⌃⌥** (fn + control + option) to **Compose**: ramble it out, and a panel writes it up as a
  message, email, bullets and so on. Say "as bullet points" or "make it an email" to steer it, or pick
  a style in the panel. Press Return to insert it. Everything is kept in the **Library** (⌘L
  from the menu). Cleanup and Compose need the optional model below.
- **Double-tap fn** for hands-free; tap fn again to finish.
- **Esc** cancels.
- Say **"scratch that"** on its own to undo the last dictation (Murmur presses ⌘Z in that app). End
  a sentence with "scratch that" and nothing from it is typed.
- **Snippets** (menu bar icon → Snippets, or Settings… → Snippets): say a phrase like "my email" on
  its own and saved text is typed instead. Or click one in the menu to type it.
- **Recent** (menu bar icon) holds your last 10 dictations: click one to copy it again. If you
  finish talking while a list or button is selected rather than a text box, Murmur leaves the
  words on the clipboard instead of losing them; press ⌘V where you want them.
- **Vocabulary** (menu bar icon → Add Word…) teaches it names and jargon it misspells.
- **Settings… → Speech → Microphone** picks which mic to use. If it keeps saying "No sound from …", pick
  your mic there (a webcam or display mic, say) and check its level in System Settings → Sound →
  Input.
- The **pill** (Listening, Transcribing) sits under the menu bar. Drag it wherever it's out of
  your way, or pick a spot in Settings… → General.
- **Settings…** (⌘, from the menu) changes the hotkey (click Change… and press the key you want),
  microphone, speech model, Neural Engine, vocabulary, snippets and meeting options.
- **More → How to Use Murmur** shows all of this on one page.
- **Meeting Notes** (menu bar icon → Start Meeting Notes) records a call and writes notes. It asks for Screen &
  System Audio Recording the first time, to hear the other people. When a call starts in Zoom, Teams,
  FaceTime, Slack or a browser, Murmur offers to take notes (it never starts on its own; turn the
  offer off in Settings… → Meetings). **Live Transcript…** shows it as it's written, and every
  meeting is in the **Library** (⌘L) next to your Compose pieces.
- **Use the Neural Engine** (Settings… → Speech) runs part of speech recognition on Apple's Neural
  Engine instead of the GPU: less GPU and battery use. It's a one-time download (40 MB to 1.2 GB
  depending on the model), and the first dictation afterwards takes a minute or two while macOS
  prepares it.
- **Copy Diagnostics** (Settings… → About, or More) copies your settings and status for a bug
  report. It never includes anything you dictated or your API keys.

**Settings… → Speech** switches between the speed and accuracy options and shows how long the last
dictation took. **Settings… → Writing** shows which models clean up and compose, and lets you pick a
smaller Compose model if writing feels slow.

## Updating

When a new version is out, the menu bar menu shows **⬆︎ Update to v…**. Click it, then **Update and
Restart**: Murmur downloads it, checks it comes from the same developer, and restarts. Settings,
models, the Compose Library and permissions carry over. **Settings… → About → Check for Updates** looks
right away. (You can also download the new zip yourself and replace Murmur in Applications.)

If Murmur stops reacting to fn after an update, macOS is holding on to the old permission: open
the menu → **More → Setup…**, click **Reset Murmur's Permissions and Ask Again**, and allow them.

## Optional: cleanup (fn⌃) and Compose (fn⌃⌥)

These need a local model. On a Mac with 16 GB or more:

```sh
brew install ollama
brew services start ollama
ollama pull qwen3:4b     # cleanup
ollama pull qwen3:8b     # Compose (with 32 GB or more: qwen3:30b)
```

Murmur finds them automatically and the menu suggests the right Compose model for your Mac. On an
8 GB Mac, pull only `qwen3:4b`; Compose will use it too, just a bit less polished. Plain fn works
without any of this.
