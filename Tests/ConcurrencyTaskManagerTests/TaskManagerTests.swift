import ConcurrencyTaskManager
import XCTest

@discardableResult
func dummyTask<V>(_ v: V, nanoseconds: UInt64) async -> V {
  try? await Task.sleep(nanoseconds: nanoseconds)
  return v
}

final class TaskManagerTests: XCTestCase {

  func test_run_distinct_tasks() async {

    let manager = TaskManager()

    let events: UnfairLockAtomic<[String]> = .init([])

    manager.task(key: .distinct(), mode: .dropCurrent) {
      await dummyTask("", nanoseconds: 1)
      events.modify { $0.append("1") }
    }
    manager.task(key: .distinct(), mode: .dropCurrent) {
      await dummyTask("", nanoseconds: 1)
      events.modify { $0.append("2") }
    }
    manager.task(key: .distinct(), mode: .dropCurrent) {
      await dummyTask("", nanoseconds: 1)
      events.modify { $0.append("3") }
    }

    try? await Task.sleep(nanoseconds: 1_000_000)

    XCTAssertEqual(Set(events.value), Set(["1", "2", "3"]))

  }

  func test_drop_current_task_in_key() async {

    let manager = TaskManager()

    let events: UnfairLockAtomic<[String]> = .init([])

    for i in (0..<10) {
      try? await Task.sleep(nanoseconds: 100_000_000)
      manager.task(key: .init("request"), mode: .dropCurrent) {
        await dummyTask("", nanoseconds: 1_000_000_000)
        guard Task.isCancelled == false else { return }
        events.modify { $0.append("\(i)") }
      }
    }

    try? await Task.sleep(nanoseconds: 2_000_000_000)

    XCTAssertEqual(events.value, ["9"])
  }

  func test_wait_current_task_in_key() async {

    let manager = TaskManager()

    let events: UnfairLockAtomic<[String]> = .init([])

    manager.task(key: .init("request"), mode: .dropCurrent) {
      await dummyTask("", nanoseconds: 5_000_000)
      guard Task.isCancelled == false else { return }
      events.modify { $0.append("1") }
    }

    try? await Task.sleep(nanoseconds: 1_000)

    manager.task(key: .init("request"), mode: .waitInCurrent) {
      await dummyTask("", nanoseconds: 5_000_000)
      guard Task.isCancelled == false else { return }
      events.modify { $0.append("2") }
    }

    try? await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertEqual(events.value, ["1", "2"])
  }

  func test_isRunning() async {

    let manager = TaskManager()

    let callCount = UnfairLockAtomic<Int>(0)
    let _isRunning = UnfairLockAtomic<Bool>(false)
    manager.setIsRunning(false)

    _ = manager.task(key: .init("request"), mode: .waitInCurrent) {
      print("done 1")
      callCount.modify { $0 += 1 }
      XCTAssert(_isRunning.value == true)
    }

    _ = manager.task(key: .init("request"), mode: .waitInCurrent) {
      print("done 2")
      callCount.modify { $0 += 1 }
      XCTAssert(_isRunning.value == true)
    }

    try? await Task.sleep(nanoseconds: 1_000_000_000)

    _isRunning.modify { $0 = true }
    manager.setIsRunning(true)

    try? await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertEqual(callCount.value, 2)
  }

  func test_cancel_specific_key() async {
    let manager = TaskManager()

    let events: UnfairLockAtomic<[String]> = .init([])

    // Start tasks with different keys
    manager.task(key: .init("key1"), mode: .dropCurrent) {
      await dummyTask("", nanoseconds: 1_000_000_000)
      guard Task.isCancelled == false else { return }
      events.modify { $0.append("key1") }
    }

    manager.task(key: .init("key2"), mode: .dropCurrent) {
      await dummyTask("", nanoseconds: 1_000_000_000)
      guard Task.isCancelled == false else { return }
      events.modify { $0.append("key2") }
    }

    manager.task(key: .init("key3"), mode: .dropCurrent) {
      await dummyTask("", nanoseconds: 1_000_000_000)
      guard Task.isCancelled == false else { return }
      events.modify { $0.append("key3") }
    }

    // Give tasks time to start
    try? await Task.sleep(nanoseconds: 100_000_000)

    // Cancel only key2
    manager.cancel(key: .init("key2"))

    // Wait for remaining tasks to complete
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    // key1 and key3 should complete, key2 should be cancelled
    XCTAssertEqual(Set(events.value), Set(["key1", "key3"]))
  }
  
  func test_cancel_key_with_multiple_queued_tasks() async {
    let manager = TaskManager()

    let events: UnfairLockAtomic<[String]> = .init([])

    // Queue multiple tasks on the same key
    manager.task(key: .init("queue"), mode: .waitInCurrent) {
      await dummyTask("", nanoseconds: 500_000_000)
      guard Task.isCancelled == false else { return }
      events.modify { $0.append("task1") }
    }

    manager.task(key: .init("queue"), mode: .waitInCurrent) {
      await dummyTask("", nanoseconds: 500_000_000)
      guard Task.isCancelled == false else { return }
      events.modify { $0.append("task2") }
    }

    manager.task(key: .init("queue"), mode: .waitInCurrent) {
      await dummyTask("", nanoseconds: 500_000_000)
      guard Task.isCancelled == false else { return }
      events.modify { $0.append("task3") }
    }

    // Give first task time to start
    try? await Task.sleep(nanoseconds: 100_000_000)

    // Cancel all tasks for this key
    manager.cancel(key: .init("queue"))

    // Wait to ensure no tasks complete
    try? await Task.sleep(nanoseconds: 2_000_000_000)

    // No tasks should have completed
    XCTAssertEqual(events.value, [])
  }
  
  func test_cancel_nonexistent_key() async {
    let manager = TaskManager()

    // This should not crash
    manager.cancel(key: .init("nonexistent"))

    // Verify manager still works after cancelling nonexistent key
    let expectation = XCTestExpectation(description: "Task completes")

    manager.task(key: .init("test"), mode: .dropCurrent) {
      expectation.fulfill()
    }

    await fulfillment(of: [expectation], timeout: 1.0)
  }
}
