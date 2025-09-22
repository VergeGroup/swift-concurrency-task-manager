import ConcurrencyTaskManager
import Testing

@Suite struct SimpleTest {

  @Test func simpleTask() async {
    let manager = TaskManager()

    let completed = UnfairLockAtomic<Bool>(false)

    let task = manager.task(key: .init("test"), mode: .dropCurrent) {
      completed.modify { $0 = true }
    }

    _ = try? await task.value

    #expect(completed.value)
  }
}