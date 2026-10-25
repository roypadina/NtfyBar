import Foundation

/// A plugin popup on its way to the screen: the validated spec plus what's needed to call the
/// plugin back when one of its buttons is pressed.
public struct PluginPopupRequest: Equatable, Sendable {
    public var pluginId: String
    public var pluginName: String
    public var spec: PopupSpec
    public var topicId: UUID
    public var messageId: String
    public var label: String
    /// The trigger topic's popup settings: position/level when the plugin doesn't choose.
    public var defaults: PopupSettings

    public init(pluginId: String, pluginName: String, spec: PopupSpec, topicId: UUID, messageId: String, label: String,
                defaults: PopupSettings = PopupSettings()) {
        self.pluginId = pluginId
        self.pluginName = pluginName
        self.spec = spec
        self.topicId = topicId
        self.messageId = messageId
        self.label = label
        self.defaults = defaults
    }

    public var content: PopupContent {
        var c = spec.content(key: "plugin-\(pluginId)-\(topicId.uuidString)-\(messageId)", label: label, pluginName: pluginName,
                             topicId: topicId, messageId: messageId, defaults: defaults)
        c.plugin = PopupContent.PluginRef(pluginId: pluginId, state: spec.state)
        return c
    }
}

/// Finds plugin packages (bundled, installed, local folders), validates them, and turns the
/// consented ones into providers backed by one JavaScript context per package. MaccyPlus loader
/// semantics: a bad manifest skips the package, a bad provider skips only itself, reload any time.
@MainActor
public final class PluginManager {
    public enum Source: Equatable, Sendable {
        case bundled, installed, local(String)

        public var key: String {
            switch self {
            case .bundled: "bundled"
            case .installed: "installed"
            case let .local(path): "local:" + path
            }
        }
    }

    public enum State: Equatable, Sendable { case active, needsConsent, disabled, invalid }

    public struct Package: Identifiable, Equatable, Sendable {
        public var id: String
        public var manifest: PluginManifest?
        public var folder: URL
        public var source: Source
        public var state: State
        public var errors: [String]
        /// Bundled, or installed from the official marketplace. Everything else gets a badge.
        public var verified: Bool
    }

    public private(set) var packages: [Package] = []
    private var runtimes: [String: PluginRuntime] = [:]
    public let bundledDirectory: URL?
    public let installedDirectory: URL
    public let appVersion: String
    private let registry: ProviderRegistry
    private weak var host: PluginHost?

    public init(bundledDirectory: URL?, installedDirectory: URL, appVersion: String, registry: ProviderRegistry, host: PluginHost?) {
        self.bundledDirectory = bundledDirectory
        self.installedDirectory = installedDirectory
        self.appVersion = appVersion
        self.registry = registry
        self.host = host
    }

    public func runtime(_ id: String) -> PluginRuntime? { runtimes[id] }
    public func package(_ id: String) -> Package? { packages.first { $0.id == id } }

    /// Permissions in force for a package from `source`: what the user granted, for this exact
    /// source, limited to what the manifest declares.
    public static func effectivePermissions(_ manifest: PluginManifest, source: Source, config: Config) -> Set<Permission> {
        guard let grant = config.plugins.grants[manifest.id], grant.source == source.key else { return [] }
        return Set(grant.permissions.compactMap(Permission.init(rawValue:))).intersection(manifest.grantedPermissions)
    }

    public static func needsConsent(_ manifest: PluginManifest, source: Source, config: Config) -> Bool {
        guard let grant = config.plugins.grants[manifest.id], grant.source == source.key else { return true }
        return !Set(manifest.permissions).isSubset(of: Set(grant.consented))
    }

    public func reload(config: Config) {
        registry.removePluginProviders()
        runtimes.removeAll()
        var found: [Package] = []
        var seen = Set<String>()
        for (folder, source) in discover(config) {
            var pkg = load(folder, source: source, config: config)
            if pkg.state != .invalid, seen.contains(pkg.id) {
                pkg.state = .invalid
                pkg.errors.append("another package with the id \(pkg.id) is already loaded")
            }
            if pkg.state != .invalid { seen.insert(pkg.id) }
            if pkg.state == .active, let manifest = pkg.manifest {
                pkg.errors += activate(manifest, folder: folder, source: source, config: config)
                if runtimes[pkg.id] == nil { pkg.state = .invalid }
            }
            found.append(pkg)
        }
        packages = found
    }

    private func discover(_ config: Config) -> [(URL, Source)] {
        var out: [(URL, Source)] = []
        if let bundled = bundledDirectory { out += subfolders(bundled).map { ($0, .bundled) } }
        out += subfolders(installedDirectory).map { ($0, .installed) }
        for path in config.plugins.localFolders {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("plugin.json").path) {
                out.append((url, .local(url.path)))
            } else {
                out += subfolders(url).map { ($0, .local($0.path)) }
            }
        }
        return out
    }

    private func subfolders(_ dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return items.filter {
            !$0.lastPathComponent.hasPrefix(".")
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && FileManager.default.fileExists(atPath: $0.appendingPathComponent("plugin.json").path)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func load(_ folder: URL, source: Source, config: Config) -> Package {
        var pkg = Package(id: folder.lastPathComponent, manifest: nil, folder: folder, source: source, state: .invalid, errors: [],
                          verified: source == .bundled)
        let manifestURL = folder.appendingPathComponent("plugin.json")
        guard let size = Self.fileSize(manifestURL), size <= PluginManifest.maxFileBytes,
              let data = try? Data(contentsOf: manifestURL) else {
            pkg.errors = ["plugin.json is missing or too large"]
            return pkg
        }
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            pkg.errors = ["plugin.json is not valid: \(error.localizedDescription)"]
            return pkg
        }
        pkg.id = manifest.id
        pkg.manifest = manifest
        var sizes: [String: Int] = [:]
        for name in manifest.files where PluginManifest.isSafeFileName(name) {
            if let s = Self.fileSize(folder.appendingPathComponent(name)) { sizes[name] = s }
        }
        let errors = manifest.packageErrors(folderName: source == .bundled || source == .installed ? folder.lastPathComponent : nil,
                                            fileSizes: sizes, appVersion: appVersion)
        guard errors.isEmpty else {
            pkg.errors = errors
            return pkg
        }
        if source == .installed {
            pkg.verified = config.plugins.installedFrom[manifest.id] == PluginSettings.officialMarketplace
        }
        // NtfyBar's own name and id space only from verified sources (no look-alike plugins).
        if !pkg.verified, manifest.id.hasPrefix("com.ntfybar.") || (manifest.author?.name ?? "").localizedCaseInsensitiveContains("ntfybar")
            || manifest.name.localizedCaseInsensitiveContains("ntfybar") {
            pkg.errors = ["the NtfyBar name and com.ntfybar.* ids are reserved for official plugins"]
            return pkg
        }
        if config.plugins.disabledIds.contains(manifest.id) {
            pkg.state = .disabled
        } else if Self.needsConsent(manifest, source: source, config: config) {
            pkg.state = .needsConsent
        } else {
            pkg.state = .active
        }
        return pkg
    }

    /// Builds the JS context with exactly the granted permissions and registers valid providers.
    private func activate(_ manifest: PluginManifest, folder: URL, source: Source, config: Config) -> [String] {
        guard let host else { return ["no plugin host"] }
        guard let script = try? String(contentsOf: folder.appendingPathComponent(manifest.entry), encoding: .utf8) else {
            return ["cannot read \(manifest.entry)"]
        }
        let runtime: PluginRuntime
        do {
            runtime = try PluginRuntime(pluginId: manifest.id, script: script,
                                        granted: Self.effectivePermissions(manifest, source: source, config: config), host: host)
        } catch {
            Log.plugins.error("\(manifest.id, privacy: .public): \(String(describing: error), privacy: .public)")
            return [String(describing: error)]
        }
        runtimes[manifest.id] = runtime
        var errors: [String] = []
        for p in manifest.providers {
            var problems = manifest.providerErrors(p)
            if problems.isEmpty, !runtime.hasFunction(p.function) { problems.append("function \(p.function) is not defined") }
            guard problems.isEmpty else {
                errors.append("provider \(p.id) skipped: " + problems.joined(separator: "; "))
                continue
            }
            let d = ProviderDescriptor(id: p.id, kind: p.kind == "condition" ? .condition : .action, name: p.name,
                                       description: p.description, params: p.params ?? [], packageId: manifest.id)
            let function = p.function, name = manifest.name, pluginId = manifest.id
            if d.kind == .condition {
                registry.register(d) { [weak runtime] ctx, params in
                    guard let runtime else { throw PluginError.unavailable }
                    return try runtime.condition(function, ctx: ctx, params: params)
                }
            } else {
                registry.register(d) { [weak runtime] ctx, params in
                    guard let runtime else { throw PluginError.unavailable }
                    guard let spec = try runtime.action(function, ctx: ctx, params: params) else { return ActionOutput() }
                    return ActionOutput([.pluginPopup(PluginPopupRequest(pluginId: pluginId, pluginName: name, spec: spec,
                                                                         topicId: ctx.topic.id, messageId: ctx.message.ntfy.id,
                                                                         label: ctx.label, defaults: ctx.topic.popup.settings(timeoutSec: 0)))])
                }
            }
        }
        return errors
    }

    static func fileSize(_ url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular else { return nil }
        return (attrs[.size] as? NSNumber)?.intValue
    }
}
