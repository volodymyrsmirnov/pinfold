@testable import Pinfold
import Testing

@MainActor
struct StorageApplyQueueTests {
    @Test func operationsRunInCallOrderWithoutOverlap() async {
        let queue = StorageApplyQueue()
        var log: [String] = []
        var running = 0
        var maxRunning = 0

        func work(_ name: String, yields: Int) -> @MainActor () async -> Void {
            {
                running += 1
                maxRunning = max(maxRunning, running)
                log.append("start \(name)")
                for _ in 0 ..< yields {
                    await Task.yield()
                }
                log.append("end \(name)")
                running -= 1
            }
        }

        // Main-actor tasks start FIFO, so `run` is called in slow, fast, mid order.
        let slow = Task { await queue.run(work("slow", yields: 20)) }
        let fast = Task { await queue.run(work("fast", yields: 0)) }
        let mid = Task { await queue.run(work("mid", yields: 5)) }
        await slow.value
        await fast.value
        await mid.value

        #expect(maxRunning == 1)
        #expect(log == ["start slow", "end slow", "start fast", "end fast", "start mid", "end mid"])
    }

    @Test func laterOperationSeesStateLeftByEarlierOne() async {
        let queue = StorageApplyQueue()
        var value = 0
        let first = Task {
            await queue.run {
                await Task.yield()
                value = 1
            }
        }
        var seen = -1
        let second = Task { await queue.run { seen = value } }
        await first.value
        await second.value
        #expect(seen == 1)
    }
}
