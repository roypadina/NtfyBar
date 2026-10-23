# Contributing to NtfyBar

Thanks for helping! Bug reports, ideas and pull requests are welcome.

## Ground rules

- `main` is protected: changes land through pull requests, CI must pass, and the maintainer reviews
  and squash-merges. One change per PR.
- Smallest diff that solves the problem; match the surrounding style; no drive-by refactors.
- **Never commit real topic names, server addresses, credentials or personal data** — not in code,
  tests, screenshots, logs or commit messages. Topic names work like passwords. Use obviously fake
  ones (`ntfybar-9f3a1c7b2e`) and `example.com` hosts.
- New behaviour comes with a test in `Tests/NtfyBarCoreTests`.

## Build and test

Needs macOS 14+ and Xcode 16 or later (Swift 6). No other dependencies.

```sh
swift test                     # unit + integration tests (no network)
Scripts/package_app.sh         # dist/NtfyBar.app (universal); RELEASE=1 also makes dist/NtfyBar.zip
```

Run the packaged app from `/Applications` (copy `dist/NtfyBar.app` there). `swift run` starts the
app without a bundle: **macOS notifications don't work** (no bundle identifier) and the bundled
plugins aren't found. Unknown `--flags` are refused instead of starting the GUI.

Optional, never in CI:

```sh
NTFYBAR_LIVE_TEST=1 swift test --filter Live          # real ntfy.sh, random throwaway topic
NTFYBAR_PLUGINS_REPO=../NtfyBar-Plugins swift test --filter MarketplaceRepo   # marketplace cross-check
```

Screenshots for the README and wiki are rendered off screen with demo data, never from a real setup:

```sh
dist/NtfyBar.app/Contents/MacOS/NtfyBar --render-popup popup.png
NTFYBAR_RENDER_TAB=topics dist/NtfyBar.app/Contents/MacOS/NtfyBar --render-settings settings.png
dist/NtfyBar.app/Contents/MacOS/NtfyBar --render-history history.png
```

`NTFYBAR_TEST=1` + `NTFYBAR_CONFIG_DIR=<empty dir>` runs the app on a throwaway config and prints
each effect (notify, popup, command, …) to stdout.

## Architecture

```
Sources/NtfyBarCore      pure logic, Swift 6 strict concurrency, fully unit-tested
  Config/                config.json / rules.json / state.json (tolerant decoding, mode 600)
  Stream/                one /json stream per server: reconnect, backoff, since=, keepalive watchdog
  History/               SQLite message store (dedupe, paging, search, retention)
  Dispatch/              message → Effects (topic defaults, rules, catch-up, flood guard, pause)
  Rules/                 rule engine, built-in conditions/actions, templates
  Commands/  Publish/    shell commands (env + stdin only), publishing, quiet hours, ntfy http actions
  Popup/                 what a popup shows (buttons, priority, attachment)
  Plugins/               manifest, JavaScriptCore runtime + permission bridge, loader, marketplace
  Engine.swift           wires it together; the app observes it
Sources/NtfyBarApp       SwiftUI + AppKit (Swift 5 mode): menu, popup panel, Settings, History,
                         notifications, renders
Resources/BundledPlugins plugins shipped in the app (copies of NtfyBar-Plugins entries)
Tests/NtfyBarCoreTests   Swift Testing
```

The Dispatcher only *decides* (it returns `Effect`s); `EffectPerformer` in the app does them. That
keeps every decision testable without AppKit.

Logs: `/usr/bin/log show --info --last 15m --predicate 'subsystem == "com.padina.ntfybar"'`.

## Plugins

Plugin authoring lives in [NtfyBar-Plugins](https://github.com/roypadina/NtfyBar-Plugins). Changes
to the plugin runtime or permission model here need tests in `PluginTests.swift` — every permission
must stay *absent → fails, granted → works, revoked → fails*.

## Feature requests and bugs

- **Feature requests:** [open one](https://github.com/roypadina/NtfyBar/issues/new?template=feature_request.yml) and say what you're trying to do; that matters more than the exact feature. Search the [open requests](https://github.com/roypadina/NtfyBar/issues?q=is%3Aissue+is%3Aopen+label%3Aenhancement) first and 👍 an existing one if it's there.
- **Bugs:** use the [bug report](https://github.com/roypadina/NtfyBar/issues/new?template=bug_report.yml).
- **Ko-fi supporters:** add your Ko-fi name to the request and it goes to the front of my queue. It's a thank-you, not a purchase: no promise on what ships or when.
- **Bigger changes:** open an issue before the PR so we agree on the shape first. Small, focused PRs can come straight in.
- Replies are best effort, evenings and weekends. I read everything.

## Code of Conduct

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).
