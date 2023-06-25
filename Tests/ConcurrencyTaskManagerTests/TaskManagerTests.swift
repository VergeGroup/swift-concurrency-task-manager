import ConcurrencyTaskManager
import XCTest

@discardableResult
func dummyTask<V>(_ v: V, nanoseconds: UInt64) async -> V {
  try? await Task.sleep(nanoseconds: nanoseconds)
  return v
}

final class TaskManagerTests: XCTestCase {

  @MainActor
  func test_run_distinct_tasks() async {

    let manager = TaskManagerActor()

    let events: UnfairLockAtomic<[String]> = .init([])

    await manager.batch {
      $0.task(key: .distinct(), mode: .dropCurrent) {
        await dummyTask("", nanoseconds: 1)
        events.modify { $0.append("1") }
      }
      $0.task(key: .distinct(), mode: .dropCurrent) {
        await dummyTask("", nanoseconds: 1)
        events.modify { $0.append("2") }
      }
      $0.task(key: .distinct(), mode: .dropCurrent) {
        await dummyTask("", nanoseconds: 1)
        events.modify { $0.append("3") }
      }
    }

    try? await Task.sleep(nanoseconds: 1_000_000)

    XCTAssertEqual(Set(events.value), Set(["1", "2", "3"]))

  }

  @MainActor
  func test_drop_current_task_in_key() async {

    let manager = TaskManagerActor()

    let events: UnfairLockAtomic<[String]> = .init([])

    for i in (0..<10) {
      try? await Task.sleep(nanoseconds: 100_000_000)
      await manager.task(key: .init("request"), mode: .dropCurrent) {
        await dummyTask("", nanoseconds: 1_000_000_000)
        guard Task.isCancelled == false else { return }
        events.modify { $0.append("\(i)") }
      }
    }

    try? await Task.sleep(nanoseconds: 2_000_000_000)

    XCTAssertEqual(events.value, ["9"])
  }

  @MainActor
  func test_wait_current_task_in_key() async {

    let manager = TaskManagerActor()

    let events: UnfairLockAtomic<[String]> = .init([])

    await manager.task(key: .init("request"), mode: .dropCurrent) {
      await dummyTask("", nanoseconds: 5_000_000)
      guard Task.isCancelled == false else { return }
      events.modify { $0.append("1") }
    }

    try? await Task.sleep(nanoseconds: 1_000)

    await manager.task(key: .init("request"), mode: .waitInCurrent) {
      await dummyTask("", nanoseconds: 5_000_000)
      guard Task.isCancelled == false else { return }
      events.modify { $0.append("2") }
    }

    try? await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertEqual(events.value, ["1", "2"])
  }

  @MainActor
  func test_isRunning() async {

    let manager = TaskManagerActor()

    var callCount = 0
    var _isRunning = false
    await manager.setIsRunning(false)

    _ = await manager.task(key: .init("request"), mode: .waitInCurrent) {
      print("done 1")
      callCount += 1
      XCTAssert(_isRunning == true)
    }

    _ = await manager.task(key: .init("request"), mode: .waitInCurrent) {
      print("done 2")
      callCount += 1
      XCTAssert(_isRunning == true)
    }

    try? await Task.sleep(nanoseconds: 1_000_000_000)

    _isRunning = true
    await manager.setIsRunning(true)

    try? await Task.sleep(nanoseconds: 1_000_000_000)

    XCTAssertEqual(callCount, 2)
  }
}
