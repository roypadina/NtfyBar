import Foundation

/// `{title} {message} {priority} {tags} {click} {topicLabel} {id} {time}` placeholders.
/// One pass, so a message that itself contains "{title}" is never expanded a second time.
public enum Template {
    public static let placeholders = ["title", "message", "priority", "tags", "click", "topicLabel", "id", "time"]

    public static func render(_ template: String, message m: Message, topicLabel: String, urlEncode: Bool = false) -> String {
        let values: [String: String] = [
            "title": m.title ?? "",
            "message": m.body,
            "priority": String(m.priority),
            "tags": m.tags.joined(separator: ","),
            "click": m.ntfy.click ?? "",
            "topicLabel": topicLabel,
            "id": m.ntfy.id,
            "time": String(m.ntfy.time)
        ]
        var out = ""
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{") {
            out += rest[..<open]
            let after = rest[rest.index(after: open)...]
            if let close = after.firstIndex(of: "}"), let value = values[String(after[..<close])] {
                out += urlEncode ? percentEncode(value) : value
                rest = after[after.index(after: close)...]
            } else {
                out += "{"
                rest = after
            }
        }
        return out + rest
    }

    /// RFC 3986 unreserved characters only; everything else (incl. & = ? # / + space) is encoded.
    public static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
