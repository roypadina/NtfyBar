import Foundation
import Testing
@testable import NtfyBarCore

/// Real /bin/zsh: message data reaches a command only through env + stdin, never as shell syntax.
@Suite("Commands")
struct CommandTests {
    let topic: TopicConfig = {
        var t = TopicConfig(serverId: UUID(), topic: "ntfybar-9f3a1c7b2e", label: "Builds")
        t.id = UUID()
        return t
    }()

    func message(_ body: String, title: String? = "Title") -> Message {
        makeMessage(topicId: topic.id, id: "cmd1", title: title, body: body, tags: ["a", "b"], click: "https://example.com")
    }

    func run(_ command: String, _ m: Message, timeout: Int = 10) async -> CommandResult {
        await CommandRunner.run(CommandSettings(command: command, timeoutSec: timeout), message: m, topic: topic)
    }

    @Test func messageArrivesInEnvAndStdin() async {
        let r = await run(#"printf '%s|%s|%s|%s|%s|%s' "$NTFY_MESSAGE" "$NTFY_TITLE" "$NTFY_TOPIC_LABEL" "$NTFY_TAGS" "$NTFY_PRIORITY" "$NTFY_ID"; cat"#,
                          message("hello"))
        #expect(r.succeeded)
        #expect(r.stdout == "hello|Title|Builds|a,b|3|cmd1hello")
    }

    @Test(arguments: ["$(touch CANARY)", "`touch CANARY`", "'; touch CANARY; '", "x\ntouch CANARY", "\"; touch CANARY; \"", "{message}"])
    func hostileMessageIsInert(_ body: String) async throws {
        let dir = tempDir()
        let r = await run("cd \(dir.path) && echo \"$NTFY_MESSAGE\" && echo \"$NTFY_TITLE\"", message(body, title: body))
        #expect(r.succeeded)
        #expect(r.stdout == body + "\n" + body + "\n", "printed literally")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("CANARY").path))
    }

    @Test func placeholdersInTheCommandAreNotSubstituted() async {
        let r = await run("echo '{message}' '{title}'", message("SECRET"))
        #expect(r.stdout == "{message} {title}\n")
    }

    @Test func runsInHomeDirectory() async {
        let r = await run("pwd", message("x"))
        #expect(r.stdout.trimmingCharacters(in: .newlines) == FileManager.default.homeDirectoryForCurrentUser.path)
    }

    @Test func timeoutKills() async {
        let start = Date()
        let r = await run("sleep 30", message("x"), timeout: 1)
        #expect(r.timedOut)
        #expect(!r.succeeded)
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func outputIsCappedAndChildNeverBlocks() async {
        let r = await run("head -c 300000 /dev/zero | tr '\\0' 'x'", message("x"))
        #expect(r.succeeded)
        #expect(r.stdout.utf8.count == CommandRunner.outputCap)
    }

    @Test func nonZeroExitAndStderr() async {
        let r = await run("echo oops >&2; exit 3", message("x"))
        #expect(r.exitCode == 3 && !r.succeeded)
        #expect(r.stderr == "oops\n")
    }

    @Test func commandThatIgnoresStdinDoesNotCrash() async {
        let big = String(repeating: "y", count: 1_000_000)
        let r = await run("exit 0", message(big))
        #expect(r.succeeded)
    }

    @Test func envIsNulFreeAndTruncated() {
        let env = CommandRunner.environment(for: message("a\0b" + String(repeating: "z", count: 100_000)), topic: topic)
        #expect(env["NTFY_MESSAGE"]?.contains("\0") == false)
        #expect(env["NTFY_MESSAGE"]?.hasPrefix("ab") == true)
        #expect((env["NTFY_MESSAGE"]?.utf8.count ?? 0) <= 64 * 1024)
        #expect(env["NTFY_TOPIC"] == "ntfybar-9f3a1c7b2e", "the user's own command may know its own topic")
    }

    @Test func shortcutNameIsOneArgument() async throws {
        let dir = tempDir()
        let name = "My Shortcut; touch \(dir.path)/CANARY"
        let r = await CommandRunner.runShortcut(name: name, message: message("x"), executable: "/bin/echo")
        #expect(r.stdout.hasPrefix("run \(name) --input-path "))
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("CANARY").path))
    }
}

@Suite("Command queue")
@MainActor
struct CommandQueueTests {
    @Test func serialPerTopicParallelAcross() async {
        let q = CommandQueue()
        let a = UUID(), b = UUID()
        var order: [String] = []
        func job(_ topic: UUID, _ name: String, _ delay: Double) -> CommandQueue.Job {
            CommandQueue.Job(topicId: topic, run: {
                try? await Task.sleep(for: .seconds(delay))
                return CommandResult(exitCode: 0, timedOut: false, stdout: name, stderr: "")
            }, onDone: { order.append($0.stdout) })
        }
        q.enqueue(job(a, "a1", 0.3))
        q.enqueue(job(a, "a2", 0.0))
        q.enqueue(job(b, "b1", 0.1))
        #expect(await eventually { order.count == 3 })
        #expect(order == ["b1", "a1", "a2"])
    }

    @Test func capDropsOldestWaiting() async {
        let q = CommandQueue(cap: 3)
        let t = UUID()
        var done: [String] = []
        func job(_ name: String, _ delay: Double = 0) -> CommandQueue.Job {
            CommandQueue.Job(topicId: t, run: {
                try? await Task.sleep(for: .seconds(delay))
                return CommandResult(exitCode: 0, timedOut: false, stdout: name, stderr: "")
            }, onDone: { done.append($0.stdout) })
        }
        q.enqueue(job("running", 0.3))
        for i in 1...5 { q.enqueue(job("w\(i)")) }
        #expect(q.pending(t) == 3)
        #expect(q.dropped == 2)
        #expect(await eventually { done.count == 4 })
        #expect(done == ["running", "w3", "w4", "w5"])
    }
}
