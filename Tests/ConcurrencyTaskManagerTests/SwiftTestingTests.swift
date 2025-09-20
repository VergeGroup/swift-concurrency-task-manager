import ConcurrencyTaskManager
import Testing

@Suite struct TaskManagerSwiftTests {

  @Test
  func simpleTask() async throws {
    let manager = TaskManagerActor()

    let completed = UnfairLockAtomic<Bool>(false)

    let task = manager.task(key: .init("test"), mode: .dropCurrent) {
      completed.modify { $0 = true }
    }

    _ = try await task.value

    #expect(completed.value == true)
  }

  @Test
  func distinctTasks() async throws {
    let manager = TaskManagerActor()

    let events = UnfairLockAtomic<[String]>([])

    let task1 = manager.task(key: .distinct(), mode: .dropCurrent) {
      events.modify { $0.append("1") }
    }

    let task2 = manager.task(key: .distinct(), mode: .dropCurrent) {
      events.modify { $0.append("2") }
    }

    let task3 = manager.task(key: .distinct(), mode: .dropCurrent) {
      events.modify { $0.append("3") }
    }

    _ = try await task1.value
    _ = try await task2.value
    _ = try await task3.value

    #expect(Set(events.value) == Set(["1", "2", "3"]))
  }

  @Test
  func cancelSpecificKey() async throws {
    let manager = TaskManagerActor()

    let events = UnfairLockAtomic<[String]>([])

    manager.task(key: .init("key1"), mode: .dropCurrent) {
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled else { return }
      events.modify { $0.append("key1") }
    }

    manager.task(key: .init("key2"), mode: .dropCurrent) {
      try? await Task.sleep(nanoseconds: 500_000_000)
      guard !Task.isCancelled else { return }
      events.modify { $0.append("key2") }
    }

    try await Task.sleep(nanoseconds: 100_000_000)

    manager.cancel(key: .init("key2"))

    try await Task.sleep(nanoseconds: 1_000_000_000)

    #expect(events.value == ["key1"])
  }
}