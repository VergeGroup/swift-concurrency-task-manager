@testable import ConcurrencyTaskManager
import Testing
import Foundation

struct TaskNodeWaitTests {

  @Test func wait_completes_after_task_finishes() async {

    let events: UnfairLockAtomic<[String]> = .init([])

    let node = TaskNode(label: "test-wait") { _ in
      try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
      events.modify {
        $0.append("task-completed")
      }
    }

    // Activate the task
    node.activate()

    // Wait should block until task completes
    await node.wait()
    events.modify { $0.append("wait-completed") }

    #expect(events.withValue { $0 } == ["task-completed", "wait-completed"])
  }

  @Test func wait_returns_immediately_for_invalidated_task() async {

    let events: UnfairLockAtomic<[String]> = .init([])

    let node = TaskNode(label: "invalidated-task") { _ in
      // This might run briefly before invalidation
      try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
      events.modify { $0.append("task-completed") }
    }

    // Activate and immediately invalidate
    node.activate()
    node.invalidate()

    // Wait should return immediately for already-invalidated task
    await node.wait()
    events.modify { $0.append("wait-completed") }

    #expect(events.withValue { $0 } == ["wait-completed"])
  }
}