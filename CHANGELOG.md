# Changelog

What changed in each Murmur release. Betas of a version carry its list as it grows. Older releases
are on the [releases page](https://github.com/kadeclifton/notetaker/releases).

## 0.2.5

- **Apple's speech recognition.** On macOS 26, Settings → Speech → Speech recognition → Apple uses
  the engine built into macOS: nothing to download, no memory used while idle, and long dictations
  show their words in the pill as you talk. Whisper stays the default.
- **Fix a Word.** Tell Murmur to always write something it keeps getting wrong the way it should be,
  like "cloud code" → "Claude Code". Recent → Fix a Word…, or Settings → Speech → Corrections.
- **Language.** Settings → Speech picks English, auto-detect, or another language.
- **Never types into password fields.** The words stay on the clipboard instead, hidden from
  clipboard managers and kept out of Recent.

## 0.2.4

- **One place for settings.** The menu's More submenu is gone: pill position, launch at login,
  Setup, How to Use, the settings and API key files, updates and Copy Diagnostics are all in
  Settings…, which also lists anything that needs fixing.

## 0.2.3

- **Meeting Notes hear FaceTime.** The call's audio now comes straight from macOS, so FaceTime and
  iPhone calls taken on your Mac are in the notes, and your mic keeps recording when the call app
  takes it over. macOS asks once to let Murmur record system audio.
- **No more made-up "Thank you."** Quiet stretches no longer turn into filler, and the notes say
  when your mic or the call stayed silent instead of summarising nothing.
- **Meeting Notes shortcut.** ⌃⌥M starts and stops Meeting Notes from anywhere
  (`meeting.shortcut` in the settings file).
- **Copy Summary.** One click copies a meeting's summary and action items, ready to paste into a
  message or an email. In the Library and the live transcript.
- **What's new, before you update.** The menu lists what a new version brings next to Restart to
  Update.
- **Updates: Release or Beta.** Settings → About picks tested releases, or new versions first.
- **Free memory when idle.** Settings → Speech picks how long the speech model stays loaded after
  you stop dictating (15 minutes by default).
- **A clearer Settings window.** A sidebar names every page instead of icons in the title bar.
- **Try it in setup.** Setup ends with a box to dictate into, and says what went wrong if nothing
  appears.
- **Recent errors in Copy Diagnostics.** The last 20 error messages, never anything you dictated,
  for bug reports.
- **Remove Murmur…** Settings → About takes Murmur and everything it stored off your Mac. Your
  Library and meeting notes stay.
- **VoiceOver.** The pill announces Listening and Transcribing, and icon-only buttons are labelled.
