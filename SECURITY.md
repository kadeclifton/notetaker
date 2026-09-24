# Security

## Reporting a problem

Please report security issues privately through GitHub: **Security → Report a vulnerability** on
https://github.com/kadeclifton/notetaker. Don't open a public issue for them. You'll get a reply
within a few days, and a fix is released through the in-app updater.

## How Murmur protects you

- Releases are signed with a Developer ID and notarized by Apple.
- The updater installs only a download that comes from GitHub over https, is signed by the same
  developer (Team ID), passes `codesign --verify` and Gatekeeper (`spctl`), and has the same bundle ID.
- API keys live in `~/.config/murmur/.env` (created readable only by you) and are sent only to the
  provider they belong to.
- Plain `http://` is used only for servers on your Mac or home network (Ollama, LM Studio).
- There is no telemetry. See [PRIVACY.md](PRIVACY.md).
