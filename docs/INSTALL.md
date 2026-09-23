# Installing Murmur

Hold a key, talk, let go: your words appear wherever you're typing. Everything runs on your Mac.

**You need:** a Mac with Apple Silicon (M1 or newer) on macOS 14 Sonoma or later, and [Homebrew](https://brew.sh).

## 1. Install the speech recognizer

In Terminal:

```sh
brew install whisper-cpp
```

No Homebrew yet? Install it first with the one-line command on [brew.sh](https://brew.sh).

## 2. Install Murmur

1. Download **Murmur-….zip** from the release page and double-click it to unzip.
2. Drag **Murmur** into your **Applications** folder.
3. Murmur isn't from the App Store, so macOS blocks it the first time. Allow it with this command in Terminal:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Murmur.app
   ```

4. Open Murmur. A waveform icon appears in the menu bar (there is no Dock icon), and a setup window opens.

## 3. Finish setup

The setup window walks you through the rest, with a button for each step:

- **Download a speech model.** "Balanced" is right for most Macs. On an 8 GB MacBook Air, "Fastest" feels snappier.
  "Most accurate" is best with names and jargon, and slower on an Air.
- **Allow the microphone.**
- **Allow Accessibility**, so Murmur can paste into other apps.
- **Allow Input Monitoring**, so Murmur can see the fn key. Then click **Restart Murmur**.

Also set System Settings → Keyboard → **Press 🌐 key to: Do Nothing**, so macOS doesn't react to fn too.

## Using it

- **Hold fn**, talk, let go: the text is typed where your cursor is.
- **Double-tap fn** for hands-free; tap fn again to finish.
- **Esc** cancels.
- **Meeting Notes** (menu bar icon → Start Meeting Notes) records a call and writes notes. It asks for Screen &
  System Audio Recording the first time, to hear the other people.

**Speech Model** in the menu switches between the speed and accuracy options and shows how long
the last dictation took. **Cleanup** turns punctuation cleanup on and off.

## Updating

Download the new zip, replace Murmur in Applications, and run the `xattr` command again. macOS
forgets Murmur's permissions on each update: open the menu → **Settings → Setup…** and click
**Reset Murmur's Permissions and Ask Again**, then allow them again.

## Optional: cleanup of punctuation and "um"s

On a Mac with 16 GB or more:

```sh
brew install ollama
brew services start ollama
ollama pull qwen3:4b
```

Murmur finds it automatically. On an 8 GB Mac, skip this; the raw transcript is already good.
