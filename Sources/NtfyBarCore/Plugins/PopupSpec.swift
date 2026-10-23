import Foundation

/// A plugin's declarative popup, as returned from JS. Validated strictly where it matters (types,
/// ranges, counts, sizes); unknown keys are ignored. Rendered by the same native popup as
/// built-in ones — plugins never get a web view or raw drawing.
public struct PopupSpec: Equatable, Sendable {
    public var title: String
    public var icon: String
    public var accent: PopupContent.Accent
    public var timeoutSec: Int?
    public var blocks: [PopupContent.Block]
    public var buttons: [PopupButton]
    public var state: JSONValue

    public struct Invalid: Error, Equatable, CustomStringConvertible {
        public var reason: String
        public var description: String { "invalid popup: \(reason)" }
    }

    static let maxBlocks = 20, maxText = 4096, maxRows = 50, maxButtons = 3, maxState = 64 * 1024

    public static func parse(_ v: JSONValue) throws -> PopupSpec {
        func fail(_ r: String) -> Invalid { Invalid(reason: r) }
        guard case let .object(o) = v else { throw fail("popup must be an object") }
        guard case let .string(title)? = o["title"], !title.isEmpty, title.count <= 200 else { throw fail("title must be a non-empty string ≤200") }
        var icon = "puzzlepiece.extension.fill"
        if let i = o["icon"] {
            guard case let .string(s) = i, s.count <= 60, s.range(of: #"^[a-z0-9.]+$"#, options: .regularExpression) != nil else {
                throw fail("icon must be an SF Symbol name")
            }
            icon = s
        }
        var accent = PopupContent.Accent.info
        if let a = o["accent"] {
            guard case let .string(s) = a, let parsed = PopupContent.Accent(rawValue: s) else { throw fail("accent must be info, success, warning or critical") }
            accent = parsed
        }
        var timeout: Int?
        if let t = o["timeoutSec"] {
            guard let n = t.int, (0...600).contains(n), case .number = t else { throw fail("timeoutSec must be 0…600") }
            timeout = n
        }
        var blocks: [PopupContent.Block] = []
        if let b = o["blocks"] {
            guard case let .array(items) = b, items.count <= maxBlocks else { throw fail("blocks must be an array of ≤\(maxBlocks)") }
            for item in items {
                guard case let .object(block) = item else { throw fail("each block must be an object") }
                if let t = block["text"] {
                    guard case let .string(s) = t, s.count <= maxText else { throw fail("text must be a string ≤\(maxText)") }
                    blocks.append(.text(s, markdown: true))
                } else if let kv = block["kv"] {
                    guard case let .array(rows) = kv, rows.count <= maxRows else { throw fail("kv must be an array of ≤\(maxRows) rows") }
                    blocks.append(.keyValue(try rows.map { row in
                        guard case let .array(pair) = row, pair.count == 2, let k = pair[0].string, let val = pair[1].string,
                              k.count <= 200, val.count <= 1000 else { throw fail("kv rows must be [key, value] strings") }
                        return PopupContent.KV(k, val)
                    }))
                } else if let p = block["progress"] {
                    guard case let .number(n) = p, (0...1).contains(n) else { throw fail("progress must be 0…1") }
                    let label = block["label"]?.string
                    blocks.append(.progress(n, label: label.map { String($0.prefix(200)) }))
                } else if let badge = block["badge"] {
                    guard case let .string(s) = badge, !s.isEmpty, s.count <= 40 else { throw fail("badge must be a string ≤40") }
                    blocks.append(.badge(s))
                }
                // A block with none of the known keys is ignored (forward compatible).
            }
        }
        var buttons: [PopupButton] = []
        if let b = o["buttons"] {
            guard case let .array(items) = b, items.count <= maxButtons else { throw fail("at most \(maxButtons) buttons") }
            for item in items {
                guard case let .string(id)? = item["id"], id.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) != nil,
                      case let .string(label)? = item["label"], !label.isEmpty, label.count <= 40 else {
                    throw fail("buttons need an id ([A-Za-z0-9_-]) and a label ≤40")
                }
                var style = PopupButton.Style.default
                if let s = item["style"] {
                    guard let str = s.string, let parsed = PopupButton.Style(rawValue: str) else { throw fail("style must be default, prominent or destructive") }
                    style = parsed
                }
                guard !buttons.contains(where: { $0.id == id }) else { throw fail("duplicate button id \(id)") }
                buttons.append(PopupButton(id: id, label: label, style: style))
            }
        }
        let state = o["state"] ?? .null
        guard state.jsonText.utf8.count <= maxState else { throw fail("state larger than 64 KB") }
        return PopupSpec(title: title, icon: icon, accent: accent, timeoutSec: timeout, blocks: blocks, buttons: buttons, state: state)
    }

    /// The native popup for this spec. Plugin buttons report back to the plugin; Dismiss is always there.
    public func content(key: String, label: String, pluginName: String, topicId: UUID?, messageId: String?) -> PopupContent {
        var buttons = self.buttons.map { PopupContent.Button(id: $0.id, label: $0.label, style: $0.style, action: .plugin($0.id)) }
        if !buttons.contains(where: { $0.style == .prominent }), !buttons.isEmpty { buttons[0].style = .prominent }
        buttons.append(PopupContent.Button(id: "dismiss", label: "Dismiss", style: buttons.isEmpty ? .prominent : .default, action: .dismiss))
        return PopupContent(key: key, header: "\(label) · \(pluginName)", date: Date(), priority: nil, icon: icon, accent: accent,
                            title: title, blocks: blocks, tags: [], attachment: nil, buttons: buttons, timeoutSec: timeoutSec ?? 0,
                            level: .floating, position: .topCenter, topicId: topicId, messageId: messageId, copyText: nil)
    }
}
