import ConcurrencyTaskManager
import XCTest

/// Tests for TaskNode wait functionality via TaskManager
final class TaskWaitTests: XCTestCase {

  func test_wait_for_queued_tasks() async throws {
    let manager = TaskManager()
    let events = UnfairLockAtomic<[String]>([])

    // Create multiple tasks that wait on each other
    let task1 = manager.task(key: .init("queue"), mode: .waitInCurrent) {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      events.modify { $0.append("task1") }
    }

    let task2 = manager.task(key: .init("queue"), mode: .waitInCurrent) {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      events.modify { $0.append("task2") }
    }

    let task3 = manager.task(key: .init("queue"), mode: .waitInCurrent) {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      events.modify { $0.append("task3") }
    }

    // Wait for all tasks to complete
    _ = try await task1.value
    _ = try await task2.value
    _ = try await task3.value

    // Tasks should execute in order
    XCTAssertEqual(events.value, ["task1", "task2", "task3"])
  }

  func test_drop_mode_cancels_previous_tasks() async throws {
    let manager = TaskManager()
    let events = UnfairLockAtomic<[String]>([])

    // First task will be cancelled
    let task1 = manager.task(key: .init("drop-test"), mode: .dropCurrent) {
      try await Task.sleep(nanoseconds: 500_000_000) // 500ms
      events.modify { $0.append("task1") }
    }

    // Give first task time to start
    try await Task.sleep(nanoseconds: 50_000_000) // 50ms

    // Second task should cancel the first
    let task2 = manager.task(key: .init("drop-test"), mode: .dropCurrent) {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      events.modify { $0.append("task2") }
    }

    // Wait for tasks
    do {
      _ = try await task1.value
      XCTFail("Task1 should have been cancelled")
    } catch is CancellationError {
      // Expected
    }

    _ = try await task2.value

    // Only task2 should complete
    XCTAssertEqual(events.value, ["task2"])
  }

  func test_concurrent_tasks_with_different_keys() async throws {
    let manager = TaskManager()
    let events = UnfairLockAtomic<[String]>([])
    let startTime = Date()

    // Tasks with different keys run concurrently
    let task1 = manager.task(key: .init("key1"), mode: .dropCurrent) {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      events.modify { $0.append("task1") }
    }

    let task2 = manager.task(key: .init("key2"), mode: .dropCurrent) {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      events.modify { $0.append("task2") }
    }

    let task3 = manager.task(key: .init("key3"), mode: .dropCurrent) {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      events.modify { $0.append("task3") }
    }

    // Wait for all tasks
    _ = try await task1.value
    _ = try await task2.value
    _ = try await task3.value

    let elapsed = Date().timeIntervalSince(startTime)

    // Should complete in ~100ms (concurrent), not ~300ms (sequential)
    XCTAssertLessThan(elapsed, 0.2, "Tasks should run concurrently")
    XCTAssertEqual(events.value.count, 3, "All tasks should complete")
  }

  func test_task_cancellation_propagation() async throws {
    let manager = TaskManager()
    let events = UnfairLockAtomic<[String]>([])

    // Create a chain of tasks
    let task1 = manager.task(key: .init("cancel-chain"), mode: .waitInCurrent) {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      guard !Task.isCancelled else {
        events.modify { $0.append("task1-cancelled") }
        return
      }
      events.modify { $0.append("task1-completed") }
    }

    let task2 = manager.task(key: .init("cancel-chain"), mode: .waitInCurrent) {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      guard !Task.isCancelled else {
        events.modify { $0.append("task2-cancelled") }
        return
      }
      events.modify { $0.append("task2-completed") }
    }

    let task3 = manager.task(key: .init("cancel-chain"), mode: .waitInCurrent) {
      try await Task.sleep(nanoseconds: 100_000_000) // 100ms
      guard !Task.isCancelled else {
        events.modify { $0.append("task3-cancelled") }
        return
      }
      events.modify { $0.append("task3-completed") }
    }

    // Give tasks time to start
    try await Task.sleep(nanoseconds: 50_000_000) // 50ms

    // Cancel all tasks for this key
    manager.cancel(key: .init("cancel-chain"))

    // Try to await tasks - they should all be cancelled
    _ = try? await task1.value
    _ = try? await task2.value
    _ = try? await task3.value

    // Should see cancellation events
    XCTAssertTrue(events.value.contains("task1-cancelled") || events.value.isEmpty)
    XCTAssertFalse(events.value.contains("task1-completed"))
    XCTAssertFalse(events.value.contains("task2-completed"))
    XCTAssertFalse(events.value.contains("task3-completed"))
  }

  func test_task_completion_order_with_wait_mode() async throws {
    let manager = TaskManager()
    let events = UnfairLockAtomic<[String]>([])
    let completionTimes = UnfairLockAtomic<[String: Date]>([:])

    // First task takes longer
    let task1 = manager.task(key: .init("order-test"), mode: .waitInCurrent) {
      try await Task.sleep(nanoseconds: 200_000_000) // 200ms
      events.modify { $0.append("task1") }
      completionTimes.modify { $0["task1"] = Date() }
    }

    // Second task is faster but should wait
    let task2 = manager.task(key: .init("order-test"), mode: .waitInCurrent) {
      try await Task.sleep(nanoseconds: 50_000_000) // 50ms
      events.modify { $0.append("task2") }
      completionTimes.modify { $0["task2"] = Date() }
    }

    // Third task is also fast but should wait
    let task3 = manager.task(key: .init("order-test"), mode: .waitInCurrent) {
      try await Task.sleep(nanoseconds: 50_000_000) // 50ms
      events.modify { $0.append("task3") }
      completionTimes.modify { $0["task3"] = Date() }
    }

    // Wait for all tasks
    _ = try await task1.value
    _ = try await task2.value
    _ = try await task3.value

    // Verify order
    XCTAssertEqual(events.value, ["task1", "task2", "task3"], "Tasks should complete in order")

    // Verify timing - task2 should complete after task1 despite being faster
    if let time1 = completionTimes.value["task1"],
       let time2 = completionTimes.value["task2"] {
      XCTAssertTrue(time2 > time1, "Task2 should complete after task1")
    }
  }

}