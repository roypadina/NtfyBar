import Foundation
@preconcurrency import JavaScriptCore

// MARK: - JavaScriptCore watchdog (private header, exported symbol)
//
// `JSContextGroupSetExecutionTimeLimit` enforces a wall-clock limit per entry into the VM — the only
// robust way to stop `while(true){}`. It lives in JSC's private JSContextRefPrivate.h, but the
// symbol is exported by the framework, so bind it by name (same approach as MaccyPlus).
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func JSContextGroupSetExecutionTimeLimit(
    _ group: JSContextGroupRef?, _ limit: Double,
    _ callback: @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool, _ context: UnsafeMutableRawPointer?)

/// What the bridge needs from the app. The engine-backed implementation is `EngineHost`.
@MainActor
public protocol PluginHost: AnyObject {
    var config: Config { get }
    var pluginDataDirectory: URL { get }
    func isGranted(_ pluginId: String, _ permission: Permission) -> Bool
    func history(topicId: UUID, before: Int64?, after: Int64?, limit: Int) -> [Message]
    func publish(pluginId: String, _ request: PublishRequest)
    func copy(_ text: String)
    func open(_ url: URL)
}

public enum PluginError: Error, Equatable, CustomStringConvertible {
    case compileFailed(String)
    case missingFunction(String)
    case timedOut
    case threw(String)
    case wrongReturnType(String)
    case permissionDenied(String)
    case disabled
    case unavailable

    public var description: String {
        switch self {
        case let .compileFailed(s): "script failed to load: \(s)"
        case let .missingFunction(f): "no function \(f)"
        case .timedOut: "took longer than 1 s and was stopped"
        case let .threw(s): "threw: \(s)"
        case let .wrongReturnType(s): "wrong return type: \(s)"
        case let .permissionDenied(p): "needs the \(p) permission"
        case .disabled: "disabled after repeated timeouts (reload plugins to retry)"
        case .unavailable: "the plugin is not loaded"
        }
    }
}

public enum PopupActionResult: Equatable, Sendable {
    case close
    case replace(PopupSpec)
}

/// One JSContext per plugin package. Nothing is injected except the `ntfy` host object, and that
/// object only has the methods whose permission is granted — each of which re-checks the grant
/// on every call. Every entry into JS runs under a 1 s watchdog; three timeouts disable the plugin
/// until the next reload.
@MainActor
public final class PluginRuntime {
    public let pluginId: String
    public private(set) var strikes = 0
    public var isDisabled: Bool { strikes >= 3 }

    private let context: JSContext
    private weak var host: PluginHost?
    private let jsonParse: JSValue
    private let jsonStringify: JSValue
    private let timeLimit: Double
    private var lastException: String?
    private var trigger: ProviderContext?
    private lazy var storage = PluginStorage(directory: host?.pluginDataDirectory ?? URL(fileURLWithPath: "/dev/null"), pluginId: pluginId)

    public init(pluginId: String, script: String, granted: Set<Permission>, host: PluginHost, timeLimit: Double = 1) throws {
        self.pluginId = pluginId
        self.host = host
        self.timeLimit = timeLimit
        guard let context = JSContext() else { throw PluginError.compileFailed("could not create a JavaScript context") }
        self.context = context
        // Captured before any plugin code runs, so a plugin can't swap them out from under us.
        jsonParse = context.objectForKeyedSubscript("JSON").objectForKeyedSubscript("parse")
        jsonStringify = context.objectForKeyedSubscript("JSON").objectForKeyedSubscript("stringify")
        context.exceptionHandler = { [weak self] _, exception in
            let text = Self.message(of: exception)
            MainActor.assumeIsolated { self?.lastException = text }
        }
        if let ref = context.jsGlobalContextRef {
            JSContextGroupSetExecutionTimeLimit(JSContextGetGroup(ref), timeLimit, { _, _ in true }, nil)
        }
        installBridge(granted)
        lastException = nil
        context.evaluateScript(script)
        if let error = lastException { throw PluginError.compileFailed(error) }
    }

    public func hasFunction(_ name: String) -> Bool {
        context.objectForKeyedSubscript(name)?.isObject == true
            && context.evaluateScript("typeof \(name) === 'function'")?.toBool() == true
    }

    // MARK: calls from the rule engine / popup

    public func condition(_ function: String, ctx: ProviderContext, params: Params) throws -> Bool {
        let r = try call(function, ctx, [.object(params)])
        guard r.isBoolean else { throw PluginError.wrongReturnType("a condition must return true or false") }
        return r.toBool()
    }

    /// nil = nothing to show; a popup needs the `ui` permission.
    public func action(_ function: String, ctx: ProviderContext, params: Params) throws -> PopupSpec? {
        let r = try call(function, ctx, [.object(params)])
        if r.isUndefined || r.isNull { return nil }
        guard case let .object(o)? = toJSON(r), let popup = o["popup"] else {
            throw PluginError.wrongReturnType("an action must return undefined or {popup: …}")
        }
        guard host?.isGranted(pluginId, .ui) == true else { throw PluginError.permissionDenied(Permission.ui.rawValue) }
        return try PopupSpec.parse(popup)
    }

    public func popupAction(ctx: ProviderContext, buttonId: String, state: JSONValue) throws -> PopupActionResult {
        guard hasFunction("onPopupAction") else { return .close }
        let r = try call("onPopupAction", ctx, [.string(buttonId), state])
        if r.isUndefined || r.isNull { return .close }
        guard case let .object(o)? = toJSON(r) else { throw PluginError.wrongReturnType("onPopupAction must return undefined, {popup} or {close: true}") }
        if let popup = o["popup"] {
            guard host?.isGranted(pluginId, .ui) == true else { throw PluginError.permissionDenied(Permission.ui.rawValue) }
            return .replace(try PopupSpec.parse(popup))
        }
        if o["close"]?.bool == true { return .close }
        throw PluginError.wrongReturnType("onPopupAction must return undefined, {popup} or {close: true}")
    }

    private func call(_ name: String, _ ctx: ProviderContext, _ args: [JSONValue]) throws -> JSValue {
        guard !isDisabled else { throw PluginError.disabled }
        guard hasFunction(name), let fn = context.objectForKeyedSubscript(name) else { throw PluginError.missingFunction(name) }
        let redactor = Redactor(config: host?.config ?? Config())
        let ctxJSON = JSONValue.object([
            "message": redactor.pluginMessage(ctx.message),
            "topic": .object(["id": .string(ctx.topic.id.uuidString), "label": .string(redactor.redact(ctx.topic.displayLabel))])
        ])
        trigger = ctx
        defer { trigger = nil }
        lastException = nil
        let start = Date()
        let result = fn.call(withArguments: [fromJSON(ctxJSON)] + args.map { fromJSON($0) })
        if let error = lastException {
            lastException = nil
            if Date().timeIntervalSince(start) >= timeLimit * 0.9 || error.localizedCaseInsensitiveContains("terminated") {
                strikes += 1
                Log.plugins.error("\(self.pluginId, privacy: .public) timed out (\(self.strikes, privacy: .public)/3)")
                throw PluginError.timedOut
            }
            throw PluginError.threw(error)
        }
        return result ?? JSValue(undefinedIn: context)
    }

    // MARK: JSON bridging (via the context's own JSON, captured at start)

    private func fromJSON(_ v: JSONValue) -> JSValue {
        jsonParse.call(withArguments: [v.jsonText]) ?? JSValue(undefinedIn: context)
    }

    private func toJSON(_ v: JSValue?) -> JSONValue? {
        guard let v, !v.isUndefined else { return nil }
        guard let s = jsonStringify.call(withArguments: [v]), s.isString else { return nil }
        return JSONValue.parse(s.toString())
    }

    private static func message(of exception: JSValue?) -> String {
        guard let exception else { return "unknown error" }
        if let m = exception.objectForKeyedSubscript("message"), !m.isUndefined, let s = m.toString(), !s.isEmpty { return s }
        return exception.toString() ?? "unknown error"
    }

    // MARK: the `ntfy` object

    private func installBridge(_ granted: Set<Permission>) {
        let ntfy = JSValue(newObjectIn: context)!
        typealias Fn1 = @convention(block) (JSValue?) -> JSValue?
        typealias Fn2 = @convention(block) (JSValue?, JSValue?) -> JSValue?

        func set(_ object: JSValue, _ name: String, _ block: Any) {
            object.setObject(block, forKeyedSubscript: name as NSString)
        }

        if granted.contains(.historyRead) {
            let fn: Fn1 = { [weak self] opts in MainActor.assumeIsolated { self?.history(opts) } }
            set(ntfy, "history", fn)
        }
        if granted.contains(.topicsRead) {
            let fn: Fn1 = { [weak self] _ in MainActor.assumeIsolated { self?.topics() } }
            set(ntfy, "topics", fn)
        }
        if granted.contains(.publish) {
            let fn: Fn1 = { [weak self] msg in MainActor.assumeIsolated { self?.publish(msg) } }
            set(ntfy, "publish", fn)
        }
        if granted.contains(.clipboardWrite) {
            let fn: Fn1 = { [weak self] text in MainActor.assumeIsolated { self?.copy(text) } }
            set(ntfy, "copy", fn)
        }
        if granted.contains(.openURL) {
            let fn: Fn1 = { [weak self] url in MainActor.assumeIsolated { self?.openURL(url) } }
            set(ntfy, "openURL", fn)
        }
        if granted.contains(.storage) {
            let store = JSValue(newObjectIn: context)!
            let get: Fn1 = { [weak self] key in MainActor.assumeIsolated { self?.storageGet(key) } }
            let put: Fn2 = { [weak self] key, value in MainActor.assumeIsolated { self?.storageSet(key, value) } }
            let remove: Fn1 = { [weak self] key in MainActor.assumeIsolated { self?.storageRemove(key) } }
            set(store, "get", get)
            set(store, "set", put)
            set(store, "remove", remove)
            ntfy.setObject(store, forKeyedSubscript: "storage" as NSString)
        }
        context.setObject(ntfy, forKeyedSubscript: "ntfy" as NSString)
    }

    /// Per-call re-check: a revoked permission fails even before the context is rebuilt.
    private func allowed(_ p: Permission) -> Bool {
        if host?.isGranted(pluginId, p) == true { return true }
        fail("permission \(p.rawValue) is not granted")
        return false
    }

    private func fail(_ message: String) {
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    private func ok(_ v: JSONValue) -> JSValue { fromJSON(v) }

    private func history(_ opts: JSValue?) -> JSValue? {
        guard allowed(.historyRead), let host else { return nil }
        let o = toJSON(opts)
        let triggerTopic = trigger?.topic.id
        let requested = o?["topicId"]?.string.flatMap(UUID.init(uuidString:))
        guard let topicId = requested ?? triggerTopic else { fail("history needs a topicId here"); return nil }
        if topicId != triggerTopic {
            guard allowed(.topicsRead) else { return nil }
            guard host.config.topic(topicId) != nil else { fail("unknown topicId"); return nil }
        }
        let limit = min(max(o?["limit"]?.int ?? 50, 1), 200)
        let before = o?["before"]?.int.map(Int64.init)
        let after = o?["after"]?.int.map(Int64.init)
        let redactor = Redactor(config: host.config)
        let rows = host.history(topicId: topicId, before: before, after: after, limit: limit)
        return ok(.array(rows.map { redactor.pluginMessage($0) }))
    }

    private func topics() -> JSValue? {
        guard allowed(.topicsRead), let host else { return nil }
        let redactor = Redactor(config: host.config)
        return ok(.array(host.config.topics.map {
            .object(["id": .string($0.id.uuidString), "label": .string(redactor.redact($0.displayLabel))])
        }))
    }

    private func publish(_ arg: JSValue?) -> JSValue? {
        guard allowed(.publish), let host else { return nil }
        guard case let .object(o)? = toJSON(arg),
              let topicId = o["topicId"]?.string.flatMap(UUID.init(uuidString:)), host.config.topic(topicId) != nil else {
            fail("publish needs the topicId of one of your topics")
            return nil
        }
        guard let message = o["message"]?.string, !message.isEmpty, message.count <= 4096 else {
            fail("publish needs a message (≤4096 characters)")
            return nil
        }
        var tags: [String] = []
        if case let .array(a)? = o["tags"] { tags = a.compactMap(\.string).prefix(10).map { String($0.prefix(64)) } }
        let req = PublishRequest(topicId: topicId, title: o["title"]?.string.map { String($0.prefix(256)) }, message: message,
                                 priority: min(5, max(1, o["priority"]?.int ?? 3)), tags: tags,
                                 click: SafeOpen.url(o["click"]?.string)?.absoluteString)
        host.publish(pluginId: pluginId, req)
        return ok(.bool(true))
    }

    private func copy(_ arg: JSValue?) -> JSValue? {
        guard allowed(.clipboardWrite), let host else { return nil }
        guard let arg, arg.isString, let text = arg.toString(), text.utf8.count <= 1024 * 1024 else {
            fail("copy needs a string up to 1 MB")
            return nil
        }
        host.copy(text)
        return ok(.bool(true))
    }

    private func openURL(_ arg: JSValue?) -> JSValue? {
        guard allowed(.openURL), let host else { return nil }
        guard let arg, arg.isString, let url = SafeOpen.url(arg.toString()) else {
            fail("openURL only opens http(s) URLs")
            return nil
        }
        host.open(url)
        return ok(.bool(true))
    }

    private func storageKey(_ arg: JSValue?) -> String? {
        guard let arg, arg.isString, let key = arg.toString(), !key.isEmpty, key.count <= 200 else {
            fail("storage keys are non-empty strings up to 200 characters")
            return nil
        }
        return key
    }

    private func storageGet(_ key: JSValue?) -> JSValue? {
        guard allowed(.storage), let key = storageKey(key) else { return nil }
        return storage.get(key).map { ok($0) } ?? JSValue(undefinedIn: context)
    }

    private func storageSet(_ key: JSValue?, _ value: JSValue?) -> JSValue? {
        guard allowed(.storage), let key = storageKey(key) else { return nil }
        guard let v = toJSON(value) else { fail("storage values must be JSON"); return nil }
        do {
            try storage.set(key, v)
            return ok(.bool(true))
        } catch {
            fail("storage is limited to 1 MB per plugin")
            return nil
        }
    }

    private func storageRemove(_ key: JSValue?) -> JSValue? {
        guard allowed(.storage), let key = storageKey(key) else { return nil }
        storage.remove(key)
        return ok(.bool(true))
    }
}

/// `PluginData/<id>.json`, one JSON object per plugin, at most 1 MB, mode 600.
@MainActor
final class PluginStorage {
    static let cap = 1024 * 1024
    private let url: URL
    private var values: [String: JSONValue]

    init(directory: URL, pluginId: String) {
        url = directory.appendingPathComponent(pluginId + ".json")
        values = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
    }

    func get(_ key: String) -> JSONValue? { values[key] }

    func set(_ key: String, _ value: JSONValue) throws {
        var next = values
        next[key] = value
        let data = try JSONEncoder().encode(next)
        guard data.count <= Self.cap else { throw PluginError.threw("storage full") }
        try write(data)
        values = next
    }

    func remove(_ key: String) {
        values[key] = nil
        if let data = try? JSONEncoder().encode(values) { try? write(data) }
    }

    private func write(_ data: Data) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
