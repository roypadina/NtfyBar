import Foundation

/// What a plugin may do beyond reading the message that triggered it. Declared in plugin.json,
/// consented to by the user, and enforced: the bridge only installs `ntfy.<x>` for granted
/// permissions and re-checks the grant on every call.
public enum Permission: String, Codable, CaseIterable, Sendable, Comparable {
    case historyRead = "history.read"
    case topicsRead = "topics.read"
    case publish
    case clipboardWrite = "clipboard.write"
    case openURL
    case storage
    case ui

    public static func < (a: Permission, b: Permission) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }

    /// The consent sentence shown next to the plugin's own reason.
    public var consent: String {
        switch self {
        case .historyRead: "Read earlier messages of the topic that triggered it."
        case .topicsRead: "See the labels of all your topics (and, with history access, their messages)."
        case .publish: "Send messages to your topics, now or scheduled — at most 10 a minute, capped by quiet hours."
        case .clipboardWrite: "Put text on your clipboard."
        case .openURL: "Open web links (http/https) in your browser — a link can carry message text to that site."
        case .storage: "Keep up to 1 MB of its own data on this Mac."
        case .ui: "Show its own popups with buttons."
        }
    }

    /// Always granted, always listed.
    public static let implicitConsent = "Read each message that triggers it — title, text, tags, links — and that topic's label. Never your settings; topic names and server addresses are hidden (best-effort)."
}

public struct PluginManifest: Codable, Equatable, Sendable {
    public struct Author: Codable, Equatable, Sendable {
        public var name: String
        public var url: String?
    }

    public struct Provider: Codable, Equatable, Sendable {
        public var id: String
        public var kind: String
        public var name: String
        public var description: String
        public var function: String
        public var params: [ParamSpec]?
    }

    public struct Popup: Codable, Equatable, Sendable {
        public var engine: String
    }

    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var author: Author?
    public var apiVersion: Int
    public var minAppVersion: String?
    public var entry: String
    public var files: [String]
    public var permissions: [String]
    public var permissionReasons: [String: String]?
    public var providers: [Provider]
    public var popup: Popup?

    public var grantedPermissions: [Permission] { permissions.compactMap(Permission.init(rawValue:)).sorted() }

    public static let maxFileBytes = 2 * 1024 * 1024
    public static let maxPackageBytes = 10 * 1024 * 1024

    public static func isValidId(_ s: String) -> Bool {
        s.count <= 100 && s.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    public static func isSafeFileName(_ s: String) -> Bool {
        s.count <= 100 && !s.hasPrefix(".") && s.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil
    }

    static func isIdentifier(_ s: String) -> Bool {
        s.count <= 100 && s.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil
    }

    /// Package-level problems: any of these rejects the whole package. `fileSizes` maps every file
    /// that exists (on disk or downloaded) to its size; nil skips the existence check.
    public func packageErrors(folderName: String?, fileSizes: [String: Int]?, appVersion: String) -> [String] {
        var e: [String] = []
        if !Self.isValidId(id) { e.append("id must be reverse-DNS, lowercase (e.g. com.example.my-plugin)") }
        if let folderName, folderName != id { e.append("folder name must equal the id") }
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name.count > 60 { e.append("name is required (≤60 characters)") }
        if version.trimmingCharacters(in: .whitespaces).isEmpty || version.count > 30 { e.append("version is required") }
        if description.trimmingCharacters(in: .whitespaces).isEmpty || description.count > 120 { e.append("description is required (≤120 characters)") }
        if apiVersion != 1 { e.append("apiVersion must be 1") }
        if let min = minAppVersion, Self.compareVersions(min, appVersion) == .orderedDescending {
            e.append("needs NtfyBar \(min) or later")
        }
        if !entry.hasSuffix(".js") || !files.contains(entry) { e.append("entry must be a .js file listed in files") }
        if !files.contains("plugin.json") { e.append("files must list plugin.json") }
        if Set(files).count != files.count { e.append("files has duplicates") }
        for f in files where !Self.isSafeFileName(f) { e.append("unsafe file name: \(f)") }
        if let sizes = fileSizes {
            for f in files where sizes[f] == nil { e.append("missing file: \(f)") }
            for (f, size) in sizes where files.contains(f) && size > Self.maxFileBytes { e.append("file too large: \(f)") }
            if sizes.filter({ files.contains($0.key) }).values.reduce(0, +) > Self.maxPackageBytes { e.append("package larger than 10 MB") }
        }
        if Set(permissions).count != permissions.count { e.append("permissions has duplicates") }
        for p in permissions {
            if Permission(rawValue: p) == nil { e.append("unknown permission: \(p)") }
            let reason = permissionReasons?[p]?.trimmingCharacters(in: .whitespaces) ?? ""
            if reason.isEmpty || reason.count > 120 { e.append("permissionReasons needs a reason (≤120 characters) for \(p)") }
        }
        if let engine = popup?.engine, engine != "declarative" {
            e.append(engine == "html" ? "html popups are not supported yet (planned for v1.1)" : "unknown popup engine: \(engine)")
        }
        if providers.isEmpty { e.append("providers is empty") }
        return e
    }

    /// Provider-level problems: a bad provider is skipped, the rest of the package still loads.
    public func providerErrors(_ p: Provider) -> [String] {
        var e: [String] = []
        if !p.id.hasPrefix(id + ".") || !Self.isValidId(p.id) { e.append("provider id must start with \(id).") }
        if p.kind != "condition" && p.kind != "action" { e.append("kind must be condition or action") }
        if p.name.trimmingCharacters(in: .whitespaces).isEmpty || p.name.count > 60 { e.append("name is required") }
        if p.description.trimmingCharacters(in: .whitespaces).isEmpty || p.description.count > 120 { e.append("description is required (≤120 characters)") }
        if !Self.isIdentifier(p.function) { e.append("function must be a JavaScript identifier") }
        for param in p.params ?? [] {
            if param.kind == .choice {
                let c = param.choices ?? []
                if !(2...20).contains(c.count) || Set(c).count != c.count
                    || c.contains(where: { $0.range(of: #"^[A-Za-z0-9_-]{1,40}$"#, options: .regularExpression) == nil }) {
                    e.append("param \(param.key): choice needs 2–20 unique choices made of letters, digits, _ or -")
                }
            }
            if !Self.isIdentifier(param.key) { e.append("param key must be an identifier") }
        }
        return e
    }

    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
