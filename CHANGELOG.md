# Changelog

All notable changes to NtfyBar are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
uses [Semantic Versioning](https://semver.org/).

## [Unreleased] (1.3.0)

### Added
- Publish to a topic. Menu **Send Clipboard to “…”** sends the copied files, picture or text to the topic you last sent to; **Publish…** opens a window with topic, title, tags, priority, a message and files (Add… or drop from Finder). Text up to 2,000 bytes gets a **Copy** button on the phone, text over 4,000 bytes goes as `clip.txt`, files over 100 MB are refused. Every message carries the sender tag `ntfybar-mac` first; tag and title live under `publish` in `config.json`. Your own messages coming back are ignored, and sends from the menu or the window never hit the rules/plugins rate limit.
- Long text that arrives as `clip.txt` or `attachment.txt` (plain text, up to 1 MB) on a topic that copies or downloads is copied and shown as text instead of a file.

## [1.2.0] - 2026-10-25

### Added
- Attachments: every popup with one gets **Copy file**, **Download** and **Open folder** buttons (saved to `~/Downloads/NtfyBar`). Two new per-topic options, **Download attachments** and **Copy the downloaded attachment**, do it on arrival; with the text copy on too, the text is copied first and the file a second later. The server's sign-in is sent only to that server, never to external attachment links; automatic downloads skip files over 100 MB.

## [1.1.1] - 2026-10-24

### Added
- Edits to `config.json` and `rules.json` made outside the app (an editor, a script, an agent) apply within 2 seconds, no restart. A file that isn't valid JSON is ignored and the running settings stay.
- **Remove Topic…**, **Remove Server…** and **Remove Rule…** buttons in their editors (the − under each list still works).

### Changed
- The Settings window is bigger and can be resized.

## [1.1.0] - 2026-10-23

### Added
- Bundled plugin **Alert Card**: a big alert card with Acknowledge and Snooze (re-sent by the ntfy server after N minutes), optional auto-dismiss, position and level choice, and a times-today badge.
- Bundled plugin **Repeat & Burst**: "not seen recently" and "burst" conditions over a topic's recent history.
- Bundled plugin **Extract**: copy a regex match, or open it in a link template.
- JSON Fields 1.1.0: "JSON field changed" condition.
- Plugin API: popups can choose `position` and `level`; plugins can declare `choice` parameters; `ntfy.publish` takes `delay` (scheduled messages, 10 s – 3 days).

### Changed
- Scheduled publishes count quiet hours at the time they will arrive, and skip the loop guard (they are meant to come back and run rules).

## [1.0.1] - 2026-10-23

### Added
- About: request a feature / contribute. Two buttons open the feature request form and CONTRIBUTING.md; Ko-fi supporters' requests go to the front of the queue.

## [1.0.0] - 2026-10-23

### Added
- Menu-bar ntfy client: topics on ntfy.sh and self-hosted servers (username/password or token), live streaming with reconnect, catch-up after sleep or offline with one summary notification.
- Per-topic actions: macOS notification, NtfyBar popup, copy to clipboard, shell command (message data via environment variables and stdin only).
- Popups: non-activating floating panels with priority colour + icon + word, markdown, ntfy action buttons, keyboard shortcuts, timeout that pauses on hover, urgent popups that stay.
- Rules with built-in conditions and actions, editable in Settings or `rules.json`.
- Plugins: sandboxed JavaScript with enforced permissions, consent, a marketplace with per-file SHA-256 verification, and two bundled examples (ACK Button, JSON Fields).
- History window with search, per-topic filter, read/unread and clearing.
- Flood guard, pause (15 min / 1 h / until resumed), quiet hours for everything NtfyBar publishes.
- Settings: General, Topics (with Send Test Message), Servers, Rules, Plugins, About.
- Universal app (Apple Silicon + Intel), macOS 14+, launch at login.
