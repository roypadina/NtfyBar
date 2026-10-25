import Foundation

/// Per-server stream bookmark: the newest message time seen, so reconnects ask for `since=<it>`.
public struct StreamState: Codable, Equatable, Sendable {
    public var lastEventTime: [String: Int64] = [:]  // server id (uuidString) → unix seconds

    public init() {}
}

/// Files under one directory (mode 700), each written atomically with mode 600: topics and
/// credentials are secrets. `NTFYBAR_CONFIG_DIR` overrides the directory (tests, demo runs).
public struct ConfigStore: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    public static func defaultDirectory() -> URL {
        if let dir = ProcessInfo.processInfo.environment["NTFYBAR_CONFIG_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NtfyBar", isDirectory: true)
    }

    public var configURL: URL { directory.appendingPathComponent("config.json") }
    public var rulesURL: URL { directory.appendingPathComponent("rules.json") }
    public var stateURL: URL { directory.appendingPathComponent("state.json") }
    public var historyURL: URL { directory.appendingPathComponent("history.sqlite") }
    public var pluginsDirectory: URL { directory.appendingPathComponent("Plugins", isDirectory: true) }
    public var pluginDataDirectory: URL { directory.appendingPathComponent("PluginData", isDirectory: true) }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public func loadConfig() -> Config { load(Config.self, from: configURL) ?? Config() }
    public func saveConfig(_ config: Config) throws { try save(config, to: configURL) }

    /// "config.json" → "config.pre-1.4.json", same directory.
    public func backupURL(_ url: URL) -> URL {
        directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".pre-1.4.json")
    }

    /// Copies `url` to its `backupURL` (mode 600, overwritten), when it exists.
    public func backup(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url) else { return }
        let to = backupURL(url)
        try data.write(to: to, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
    }

    public func loadState() -> StreamState { load(StreamState.self, from: stateURL) ?? StreamState() }
    public func saveState(_ state: StreamState) throws { try save(state, to: stateURL) }

    /// Missing file → nil. Unparseable file → moved aside (never silently overwritten) and nil.
    public func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            let aside = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: aside)
            Log.config.error("unreadable \(url.lastPathComponent, privacy: .public), moved aside: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func save<T: Encodable>(_ value: T, to url: URL) throws {
        try ensureDirectory()
        let data = try Self.encoder.encode(value)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
