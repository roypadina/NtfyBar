import CryptoKit
import Foundation

public struct MarketplaceEntry: Codable, Equatable, Sendable, Identifiable {
    public struct Source: Codable, Equatable, Sendable {
        public var type: String
        public var repo: String
        public var ref: String
        public var path: String
    }

    public var id: String
    public var name: String
    public var description: String
    public var version: String
    public var permissions: [String]
    public var source: Source
    /// Every file of the package → its lowercase hex sha256.
    public var files: [String: String]
}

public struct MarketplaceIndex: Codable, Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var plugins: [MarketplaceEntry]
}

public enum MarketplaceError: Error, Equatable, CustomStringConvertible {
    case invalidEntry(String)
    case download(String)
    case checksumMismatch(String)
    case invalidPackage([String])

    public var description: String {
        switch self {
        case let .invalidEntry(s): "invalid marketplace entry: \(s)"
        case let .download(s): "download failed: \(s)"
        case let .checksumMismatch(f): "\(f) doesn't match its checksum — refused"
        case let .invalidPackage(e): "invalid package: " + e.joined(separator: "; ")
        }
    }
}

/// Downloaded and fully verified, not yet written. Consent is asked between `prepare` and `commit`.
public struct PreparedInstall: Sendable {
    public var entry: MarketplaceEntry
    public var manifest: PluginManifest
    public var files: [String: Data]
    public var marketplaceURL: String
}

/// Marketplace installs: download exactly the files the entry lists, verify every sha256 in
/// memory, check that entry and manifest agree, and only then write the package atomically.
/// Any failure leaves the installed version (if any) untouched.
public enum Marketplace {
    public static let rawBase = "https://raw.githubusercontent.com"

    public static func fetchIndex(_ url: URL, session: URLSession) async throws -> MarketplaceIndex {
        guard url.scheme?.lowercased() == "https" else { throw MarketplaceError.download("marketplaces must use https") }
        let data = try await get(url, session: session, cap: 1024 * 1024)
        do {
            return try JSONDecoder().decode(MarketplaceIndex.self, from: data)
        } catch {
            throw MarketplaceError.download("not a marketplace index")
        }
    }

    static func validate(_ e: MarketplaceEntry) throws {
        func bad(_ s: String) -> MarketplaceError { .invalidEntry(s) }
        guard PluginManifest.isValidId(e.id) else { throw bad("id") }
        guard e.source.type == "github" else { throw bad("source.type must be github") }
        guard e.source.repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { throw bad("source.repo") }
        for part in [e.source.ref, e.source.path] {
            guard part.range(of: #"^[A-Za-z0-9_./-]*$"#, options: .regularExpression) != nil, !part.contains(".."),
                  !part.hasPrefix("/") else { throw bad("source.ref / source.path") }
        }
        guard !e.source.ref.isEmpty else { throw bad("source.ref") }
        guard !e.files.isEmpty, e.files.count <= 50 else { throw bad("files") }
        for (name, hash) in e.files {
            guard PluginManifest.isSafeFileName(name) else { throw bad("file name \(name)") }
            guard hash.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else { throw bad("sha256 of \(name)") }
        }
        for p in e.permissions where Permission(rawValue: p) == nil { throw bad("unknown permission \(p)") }
    }

    public static func fileURL(_ e: MarketplaceEntry, _ name: String, rawBase: String = rawBase) -> URL? {
        let path = e.source.path.isEmpty ? "" : e.source.path + "/"
        return URL(string: "\(rawBase)/\(e.source.repo)/\(e.source.ref)/\(path)\(name)")
    }

    public static func prepare(_ entry: MarketplaceEntry, marketplaceURL: String, session: URLSession, appVersion: String,
                               rawBase: String = rawBase) async throws -> PreparedInstall {
        try validate(entry)
        var files: [String: Data] = [:]
        var total = 0
        for (name, expected) in entry.files.sorted(by: { $0.key < $1.key }) {
            guard let url = fileURL(entry, name, rawBase: rawBase) else { throw MarketplaceError.invalidEntry("file URL") }
            let data = try await get(url, session: session, cap: PluginManifest.maxFileBytes)
            total += data.count
            guard total <= PluginManifest.maxPackageBytes else { throw MarketplaceError.invalidPackage(["package larger than 10 MB"]) }
            guard sha256Hex(data) == expected.lowercased() else { throw MarketplaceError.checksumMismatch(name) }
            files[name] = data
        }
        guard let manifestData = files["plugin.json"],
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData) else {
            throw MarketplaceError.invalidPackage(["plugin.json missing or invalid"])
        }
        var errors = manifest.packageErrors(folderName: entry.id, fileSizes: files.mapValues(\.count), appVersion: appVersion)
        if manifest.id != entry.id { errors.append("manifest id differs from the marketplace entry") }
        if Set(manifest.permissions) != Set(entry.permissions) { errors.append("manifest permissions differ from the marketplace entry") }
        if Set(manifest.files) != Set(entry.files.keys) { errors.append("manifest files differ from the marketplace entry") }
        guard errors.isEmpty else { throw MarketplaceError.invalidPackage(errors) }
        return PreparedInstall(entry: entry, manifest: manifest, files: files, marketplaceURL: marketplaceURL)
    }

    /// Writes into `<dir>/.tmp-<uuid>` and swaps it in for `<dir>/<id>` in one step.
    @discardableResult
    public static func commit(_ p: PreparedInstall, into dir: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString)", isDirectory: true)
        let dest = dir.appendingPathComponent(p.manifest.id, isDirectory: true)
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for (name, data) in p.files {
                try data.write(to: tmp.appendingPathComponent(name), options: .atomic)
            }
            if fm.fileExists(atPath: dest.path) {
                _ = try fm.replaceItemAt(dest, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: dest)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
        return dest
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func get(_ url: URL, session: URLSession, cap: Int) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request, delegate: NoRedirect.shared)
        } catch {
            throw MarketplaceError.download(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw MarketplaceError.download("HTTP \(status)") }
        guard data.count <= cap else { throw MarketplaceError.invalidPackage(["\(url.lastPathComponent) is too large"]) }
        return data
    }
}
