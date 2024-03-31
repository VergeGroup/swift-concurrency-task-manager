import XCTest
import ConcurrencyTaskManager

final class TaskStackActorTests: XCTestCase {
  
  @MainActor
  func testStack_size_1() async {

    let stack = TaskStackActor(maxConcurrentTaskCount: 1)

    let events = UnfairLockAtomic<[String]>([])
    
    await stack.addTask { @MainActor in
      try! await Task.sleep(nanoseconds: 1_000_000_000)
      events.modify { $0.append("Completed-1") }
    }

    await stack.addTask { @MainActor in
      try! await Task.sleep(nanoseconds: 1_000_000_000)
      events.modify { $0.append("Completed-2") }
    }

    await stack.addTask { @MainActor in
      try! await Task.sleep(nanoseconds: 1_000_000_000)
      events.modify { $0.append("Completed-3") }
    }

    await stack.waitUntilAllItemProcessed()

    XCTAssertEqual(
      events.value,
      [
        "Completed-1",
        "Completed-3",
        "Completed-2",
      ]
    )
    
  }

  @MainActor
  func testStack_size_2() async {

    let stack = TaskStackActor(maxConcurrentTaskCount: 2)

    let events = UnfairLockAtomic<[String]>([])

    await stack.addTask { @MainActor in
      try! await Task.sleep(nanoseconds: 1_000_000_000)
      events.modify { $0.append("Completed-1") }
    }

    await stack.addTask { @MainActor in
      try! await Task.sleep(nanoseconds: 1_000_000_000)
      events.modify { $0.append("Completed-2") }
    }

    await stack.addTask { @MainActor in
      try! await Task.sleep(nanoseconds: 1_000_000_000)
      events.modify { $0.append("Completed-3") }
    }

    await stack.addTask { @MainActor in
      try! await Task.sleep(nanoseconds: 1_000_000_000)
      events.modify { $0.append("Completed-4") }
    }

    await stack.addTask { @MainActor in
      try! await Task.sleep(nanoseconds: 500_000_000)
      events.modify { $0.append("Completed-5") }
    }

    await stack.waitUntilAllItemProcessed()

    XCTAssertEqual(
      events.value,
      [
        "Completed-1",
        "Completed-2",
        "Completed-5",
        "Completed-4",
        "Completed-3",
      ]
    )

  }

//  @MainActor
//  func testCancel() async {
//    
//    let stack = TaskStackActor()
//    
//    await stack.addTask {
//      print("1")
//      try? await Task.sleep(nanoseconds: 1_000_000)
//    }
//    
//    await stack.addTask {
//      print("2", Task.isCancelled)
//    }
//    
//    await Task.sleep(nanoseconds: 1_000_000)
//    
//    stack.cancelAll()
//    
//    await Task.sleep(nanoseconds: 1_000_000)
//    
//  }
  
}
