# Changelog

All notable changes to NtfyBar are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
