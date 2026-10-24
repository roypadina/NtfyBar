import Foundation

/// Attachment download rules. Message content is attacker-controlled: only http(s) URLs, the
/// server's credentials go to that server only, and nothing is written outside `~/Downloads/NtfyBar`.
public enum AttachmentFile {
    /// Auto-download skips anything bigger; the popup buttons still work.
    public static let maxAutoBytes: Int64 = 100 * 1024 * 1024
    /// Text is copied first, the file at least this long after, so clipboard managers keep both.
    public static let copyGapSec: Double = 1

    public static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/NtfyBar", isDirectory: true)
    }

    public enum FolderAction: Equatable, Sendable { case reveal(URL), openFolder(URL) }

    /// Open folder: select the saved file when it still exists, else show the download folder.
    public static func folderAction(saved: URL?, in dir: URL = directory, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> FolderAction {
        if let saved, exists(saved) { return .reveal(saved) }
        return .openFolder(dir)
    }

    public static func autoDownloadAllowed(size: Int64?) -> Bool { (size ?? 0) <= maxAutoBytes }

    /// Authorization header only when scheme + host + port equal the server's base URL.
    public static func authHeader(for url: URL, server: ServerConfig?) -> String? {
        guard let base = server?.baseURL, let value = server?.auth.headerValue, sameOrigin(url, base) else { return nil }
        return value
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func origin(_ u: URL) -> String? {
            guard let s = u.scheme?.lowercased(), let h = u.host?.lowercased() else { return nil }
            return "\(s)://\(h):\(u.port ?? (s == "https" ? 443 : 80))"
        }
        guard let x = origin(a) else { return false }
        return x == origin(b)
    }

    /// One path component, no `..`, no leading dots, never empty.
    public static func sanitizedName(_ raw: String?, fallbackURL: URL? = nil) -> String {
        func clean(_ s: String) -> String {
            let last = s.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? ""
            var n = String(last.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && $0 != ":" })
                .replacingOccurrences(of: "..", with: "_")
            n = n.trimmingCharacters(in: .whitespaces)
            while n.hasPrefix(".") { n.removeFirst() }
            return String(n.prefix(120))
        }
        for candidate in [raw, fallbackURL?.lastPathComponent] {
            if let candidate, case let n = clean(candidate), !n.isEmpty { return n }
        }
        return "attachment"
    }

    /// "photo.jpg" -> "photo (2).jpg" -> "photo (3).jpg" ... until `exists` says no.
    public static func uniqueName(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(i))" : "\(stem) (\(i)).\(ext)"
            if !exists(candidate) { return candidate }
            i += 1
        }
    }

    /// No cookies, no cache.
    public static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    public struct Failure: Error, LocalizedError {
        public let errorDescription: String?
        public init(errorDescription: String?) { self.errorDescription = errorDescription }
    }

    /// Drops credentials when a redirect leaves the origin they were meant for.
    private final class RedirectGuard: NSObject, URLSessionTaskDelegate {
        func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                        newRequest req: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            var req = req
            if let from = task.originalRequest?.url, let to = req.url {
                guard SafeOpen.isAllowed(to) else { return completionHandler(nil) }
                if !sameOrigin(from, to) { req.setValue(nil, forHTTPHeaderField: "Authorization") }
            }
            completionHandler(req)
        }
    }

    /// Downloads into `directory` (created on demand) and returns the saved file.
    public static func download(_ a: NtfyAttachment, server: ServerConfig?, to dir: URL = directory,
                                session: URLSession = AttachmentFile.session) async throws -> URL {
        guard let url = SafeOpen.url(a.url) else { throw Failure(errorDescription: "attachment has no http(s) URL") }
        var req = URLRequest(url: url)
        req.setValue(authHeader(for: url, server: server), forHTTPHeaderField: "Authorization")
        let (tmp, response) = try await session.download(for: req, delegate: RedirectGuard())
        defer { try? FileManager.default.removeItem(at: tmp) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw Failure(errorDescription: "attachment download failed: HTTP \(http.statusCode)")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = uniqueName(sanitizedName(a.name, fallbackURL: url)) { fm.fileExists(atPath: dir.appendingPathComponent($0).path) }
        let dest = dir.appendingPathComponent(name)
        guard dest.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL else {
            throw Failure(errorDescription: "refused to write outside the download folder")
        }
        try fm.moveItem(at: tmp, to: dest)
        return dest
    }
}
