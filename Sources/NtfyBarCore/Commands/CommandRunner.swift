import Foundation

public struct CommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var timedOut: Bool
    public var stdout: String
    public var stderr: String

    public var succeeded: Bool { exitCode == 0 && !timedOut }
}

/// Runs a user-authored shell command. The command string is passed to `/bin/zsh -c` exactly as
/// the user typed it; message data is NEVER substituted into it — it arrives only as environment
/// variables and on stdin, so a hostile message can't inject shell syntax.
public enum CommandRunner {
    public static let outputCap = 64 * 1024
    static let envCap = 64 * 1024

    /// NTFY_* variables. Values are truncated to 64 KB and NUL-stripped (env strings can't hold NUL).
    public static func environment(for m: Message, topic: TopicConfig) -> [String: String] {
        func clean(_ s: String) -> String {
            let noNul = s.replacingOccurrences(of: "\0", with: "")
            return noNul.utf8.count > envCap ? String(decoding: Array(noNul.utf8.prefix(envCap)), as: UTF8.self) : noNul
        }
        return [
            "NTFY_ID": clean(m.ntfy.id),
            "NTFY_TOPIC": clean(topic.topic),  // the user's own topic, for their own command only
            "NTFY_TOPIC_LABEL": clean(topic.displayLabel),
            "NTFY_TITLE": clean(m.title ?? ""),
            "NTFY_MESSAGE": clean(m.body),
            "NTFY_PRIORITY": String(m.priority),
            "NTFY_TAGS": clean(m.tags.joined(separator: ",")),
            "NTFY_CLICK": clean(m.ntfy.click ?? ""),
            "NTFY_TIME": String(m.ntfy.time),
            "NTFY_JSON": clean(m.raw)
        ]
    }

    public static func run(_ settings: CommandSettings, message m: Message, topic: TopicConfig) async -> CommandResult {
        var env = ProcessInfo.processInfo.environment
        env.merge(environment(for: m, topic: topic)) { _, new in new }
        return await run(executable: "/bin/zsh", arguments: ["-c", settings.command], environment: env,
                         stdin: Data(m.body.utf8), timeout: Double(settings.timeoutSec))
    }

    /// `shortcuts run <name> --input-path <file>`; the name is one argv entry, never shell-parsed.
    public static func runShortcut(name: String, message m: Message, timeout: Double = 60,
                                   executable: String = "/usr/bin/shortcuts") async -> CommandResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ntfybar-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("message.txt")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(m.body.utf8).write(to: file)
        } catch {
            return CommandResult(exitCode: -1, timedOut: false, stdout: "", stderr: error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        return await run(executable: executable, arguments: ["run", name, "--input-path", file.path],
                         environment: ProcessInfo.processInfo.environment, stdin: Data(), timeout: timeout)
    }

    public static func run(executable: String, arguments: [String], environment: [String: String], stdin: Data,
                           timeout: Double) async -> CommandResult {
        signal(SIGPIPE, SIG_IGN)  // a command that closes stdin early must not kill the app
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        let out = CappedReader(outPipe.fileHandleForReading, cap: outputCap)
        let err = CappedReader(errPipe.fileHandleForReading, cap: outputCap)
        let timedOut = Flag()

        return await withCheckedContinuation { (cont: CheckedContinuation<CommandResult, Never>) in
            process.terminationHandler = { p in
                let result = CommandResult(exitCode: p.terminationStatus, timedOut: timedOut.value,
                                           stdout: out.finish(), stderr: err.finish())
                cont.resume(returning: result)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(returning: CommandResult(exitCode: -1, timedOut: false, stdout: "", stderr: error.localizedDescription))
                return
            }
            DispatchQueue.global().async {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
                try? inPipe.fileHandleForWriting.close()
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }
}

/// Drains a pipe on a background thread (so a chatty child never blocks on a full pipe) and keeps
/// only the first `cap` bytes.
final class CappedReader: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle, cap: Int) {
        DispatchQueue.global().async { [self] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.withLock {
                    if data.count < cap { data.append(chunk.prefix(cap - data.count)) }
                }
            }
            done.signal()
        }
    }

    func finish() -> String {
        _ = done.wait(timeout: .now() + 2)
        return lock.withLock { String(decoding: data, as: UTF8.self) }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
