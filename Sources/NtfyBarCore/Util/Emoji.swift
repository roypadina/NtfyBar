import Foundation

/// ntfy tags: a tag that is an emoji shortcode becomes that emoji in front of the title;
/// the rest are shown as plain tags.
public enum Emoji {
    static let map: [String: String] = {
        var m: [String: String] = [:]
        for line in EmojiData.table.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            if parts.count == 2 { m[String(parts[0])] = String(parts[1]) }
        }
        return m
    }()

    public static func emoji(for tag: String) -> String? { map[tag] }

    /// "⚠️💀 " for ["warning", "skull", "backup"]; empty when no tag is an emoji.
    public static func prefix(for tags: [String]) -> String {
        let e = tags.compactMap { map[$0] }.joined()
        return e.isEmpty ? "" : e + " "
    }

    public static func plainTags(_ tags: [String]) -> [String] { tags.filter { map[$0] == nil } }
}
