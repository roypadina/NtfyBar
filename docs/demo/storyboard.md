# NtfyBar demo — storyboard (12.6 s, loops)

Real code: `PopupView` + `PopupButtonStyle` + `PopupState` (`Sources/NtfyBarApp/PopupPanel.swift`), `Theme.swift`, `Components.swift` (`Pill`), compiled
unchanged; `PopupContent.forMessage`, `StatusSummary.line`, `Emoji` etc. from `Sources/NtfyBarCore` (compiled as the real module, `-swift-version 6`).
Status item = the app's `menubar@2x.png` template glyph + `Text(unreadCount)` (`NtfyBarApp.swift` MenuBarLabel). Menu rows copy `MenuContent`
(`NtfyBarApp.swift:55-110`), Recent rows copy `AppModel.recentTitle` (`AppModel.swift:77`). Fake data: topics "Backups", "CI builds", "Home server" on
`ntfy.sh`, topic `ntfybar-7b3e95f0c1`, host `nas.example.com`. The one non-app element is the Terminal window with the README's curl pattern.

State machine (checked in source): a message arrives → `Engine.refreshCounters` → bell shows "1" (unread). Copy = `EffectPerformer.handle .copy`:
copies + `flash("copy")` ("Copied ✓" 1.5 s), popup stays, still unread. Dismiss = `.dismiss`: `markRead()` + `PopupPanel.dismiss` (0.15 s fade) → count gone.
"Mark All Read" is `.disabled(unreadCount == 0)` → disabled once the message is read. Menu "Recent" exists because `engine.recent` is non-empty;
its first rows are "Copy Latest Message" and (the message has a click URL) "Open Latest Link". Popup Open button = prominent because `showOpen` + click URL.

| # | Scene | Start | Dur | What happens | Caption |
|---|-------|-------|-----|--------------|---------|
| 1 | script | 0.0 | 2.4 | Menu bar with the bell (no count). A Terminal window holds a 5-line `curl` (Title / Priority urgent / Click / body) to `ntfy.sh/ntfybar-7b3e95f0c1`; at 1.5 s Return: a fresh prompt appears below. | One curl from any script sends a message |
| 2 | popup arrives | 2.4 | 3.0 | At 0.3 s the real popup slides in (0.28 s ease-out, 14 pt) at the top: Urgent, "Backups", "Backup failed on nas", body, buttons Copy / Open (prominent) / Dismiss; bell gets "1". Stays, no cursor (time to read). | The popup stays on screen until you act |
| 3 | act | 5.4 | 3.0 | Cursor glides to Copy, click: button reads "Copied ✓" (1.5 s), popup stays. Cursor glides to Dismiss, click: popup fades (0.15 s), the "1" disappears at once. Cursor fades. | Copy or dismiss. Dismissed counts as read |
| 4 | menu | 8.4 | 4.2 | Click the bell: item highlights, menu opens at once ("Connected · 3 topics", Recent ▸, Send Clipboard…, Publish…, Mark All Read (disabled), …). Cursor to Recent: parent stays highlighted, submenu opens to the left (bell is at the right edge) with Copy Latest Message, Open Latest Link, four messages; cursor moves into it, hover highlights a row. Click on the desktop: menus close at once, cursor fades. | Recent messages stay one click away |

Transitions: 0.2 s crossfade between scenes; captions fade old 0–0.12 s / new 0.12–0.35 s; the last 0.2 s dissolves into scene 1's first frame (loop).
Cursor: `NSCursor.arrow`, eased glides on a slight arc, click = dip + ripple; visible only while it points at something.
Render: `./render.sh` (compiles Core as a module, then kit + app view files + scene; 30 fps frames; encode).
