import ConcurrencyTaskManager
import XCTest

final class SimpleTest: XCTestCase {

  func test_simple_task() async {
    let manager = TaskManager()

    let completed = UnfairLockAtomic<Bool>(false)

    let task = manager.task(key: .init("test"), mode: .dropCurrent) {
      completed.modify { $0 = true }
    }

    _ = try? await task.value

    XCTAssertTrue(completed.value)
  }
}