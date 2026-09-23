# Installing Murmur

Hold a key, talk, let go: your words appear wherever you're typing. Everything runs on your Mac.

**You need:** a Mac with Apple Silicon (M1 or newer) on macOS 14 Sonoma or later. About 15 minutes the
first time, mostly waiting on downloads.

## 1. Install the speech recognizer

Murmur's speech recognition (whisper.cpp) is installed with [Homebrew](https://brew.sh), the usual
way to add command-line tools to a Mac. Open **Terminal** (⌘Space, type "Terminal", press Return).

**a. Check whether you already have Homebrew:**

```sh
brew --version
```

If it prints a version such as `Homebrew 4.x`, skip to **c**. If it says `command not found`, do **b**.

**b. Install Homebrew.** Paste this line and press Return:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

- It asks for your Mac password. Nothing appears while you type it; that is normal. Press Return.
- Press Return again when it says "Press RETURN to continue".
- It may install Apple's Command Line Tools first. That can take 5 to 10 minutes.
- At the end it prints "Next steps" with two commands. Run them, or paste these two lines, which do
  the same thing:

  ```sh
  echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
  eval "$(/opt/homebrew/bin/brew shellenv)"
  ```

- Check that it worked: `brew --version` now prints a version.

**c. Install whisper.cpp:**

```sh
brew install whisper-cpp
```

That's all Terminal is needed for. (Murmur's setup window also shows these commands, with a button
to copy them.)

## 2. Install Murmur

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

## 3. Finish setup

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
  a style in the panel. Press Return to insert it. Everything is kept in the **Compose Library** (⌘L
  from the menu). Cleanup and Compose need the optional model below.
- **Double-tap fn** for hands-free; tap fn again to finish.
- **Esc** cancels.
- **Meeting Notes** (menu bar icon → Start Meeting Notes) records a call and writes notes. It asks for Screen &
  System Audio Recording the first time, to hear the other people.

**Speech Model** in the menu switches between the speed and accuracy options and shows how long
the last dictation took. **Cleanup & Compose** shows which models are in use and lets you pick a
smaller Compose Model if writing feels slow.

## Updating

When a new version is out, the menu bar menu shows **⬆︎ Update to v…**. Click it, then **Update and
Restart**: Murmur downloads it, checks it comes from the same developer, and restarts. Settings,
models, the Compose Library and permissions carry over. **Settings → Check for Updates…** looks
right away. (You can also download the new zip yourself and replace Murmur in Applications.)

If Murmur stops reacting to fn after an update, macOS is holding on to the old permission: open
the menu → **Settings → Setup…**, click **Reset Murmur's Permissions and Ask Again**, and allow them.

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
