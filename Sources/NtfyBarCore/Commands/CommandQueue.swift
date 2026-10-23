import Foundation

/// Commands run one at a time per topic, in arrival order. A topic's queue holds at most `cap`
/// waiting jobs; on overflow the oldest waiting job is dropped (and logged).
@MainActor
public final class CommandQueue {
    public struct Job: Sendable {
        public var topicId: UUID
        public var run: @Sendable () async -> CommandResult
        public var onDone: @MainActor (CommandResult) -> Void

        public init(topicId: UUID, run: @escaping @Sendable () async -> CommandResult, onDone: @escaping @MainActor (CommandResult) -> Void) {
            self.topicId = topicId
            self.run = run
            self.onDone = onDone
        }
    }

    public let cap: Int
    private var waiting: [UUID: [Job]] = [:]
    private var running: Set<UUID> = []
    public private(set) var dropped = 0

    public init(cap: Int = 50) {
        self.cap = cap
    }

    public func enqueue(_ job: Job) {
        var q = waiting[job.topicId, default: []]
        if q.count >= cap {
            q.removeFirst()
            dropped += 1
            Log.command.error("command queue full for a topic; dropped the oldest waiting command")
        }
        q.append(job)
        waiting[job.topicId] = q
        drain(job.topicId)
    }

    public func pending(_ topicId: UUID) -> Int { waiting[topicId]?.count ?? 0 }

    private func drain(_ topicId: UUID) {
        guard !running.contains(topicId), var q = waiting[topicId], !q.isEmpty else { return }
        let job = q.removeFirst()
        waiting[topicId] = q
        running.insert(topicId)
        Task {
            let result = await job.run()
            job.onDone(result)
            running.remove(topicId)
            drain(topicId)
        }
    }
}
