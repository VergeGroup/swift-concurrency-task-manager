import ConcurrencyTaskManager
import Testing

@discardableResult
func dummyTask<V>(_ v: V, nanoseconds: UInt64) async -> V {
  try? await Task.sleep(nanoseconds: nanoseconds)
  return v
}

@Suite struct TaskManagerTests {

  @Test func runDistinctTasks() async {

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

    #expect(Set(events.value) == Set(["1", "2", "3"]))

  }

  @Test func dropCurrentTaskInKey() async {

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

    #expect(events.value == ["9"])
  }

  @Test func waitCurrentTaskInKey() async {

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

    #expect(events.value == ["1", "2"])
  }

  @Test func isRunning() async {

    let manager = TaskManager()

    let callCount = UnfairLockAtomic<Int>(0)
    let _isRunning = UnfairLockAtomic<Bool>(false)
    manager.setIsRunning(false)

    _ = manager.task(key: .init("request"), mode: .waitInCurrent) {
      print("done 1")
      callCount.modify { $0 += 1 }
      #expect(_isRunning.value == true)
    }

    _ = manager.task(key: .init("request"), mode: .waitInCurrent) {
      print("done 2")
      callCount.modify { $0 += 1 }
      #expect(_isRunning.value == true)
    }

    try? await Task.sleep(nanoseconds: 1_000_000_000)

    _isRunning.modify { $0 = true }
    manager.setIsRunning(true)

    try? await Task.sleep(nanoseconds: 1_000_000_000)

    #expect(callCount.value == 2)
  }

  @Test func cancelSpecificKey() async {
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
    #expect(Set(events.value) == Set(["key1", "key3"]))
  }
  
  @Test func cancelKeyWithMultipleQueuedTasks() async {
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
    #expect(events.value == [])
  }
  
  @Test func cancelNonexistentKey() async {
    let manager = TaskManager()

    // This should not crash
    manager.cancel(key: .init("nonexistent"))

    // Verify manager still works after cancelling nonexistent key
    let completed = UnfairLockAtomic<Bool>(false)

    manager.task(key: .init("test"), mode: .dropCurrent) {
      completed.modify { $0 = true }
    }

    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

    #expect(completed.value)
  }

  @Test func staleCompletedNodeDoesNotAdvanceReplacementQueue() async {
    let manager = TaskManager()
    let key = TaskKey("stale-completion")
    let oldTaskGate = NonCooperativeGate()
    let replacementTaskGate = NonCooperativeGate()

    let oldTaskStarted = NonCooperativeGate()
    let oldOperationFinished = NonCooperativeGate()
    let replacementTaskStarted = NonCooperativeGate()
    let didStartQueuedTask = UnfairLockAtomic(false)

    let oldTask = manager.task(label: "old", key: key, mode: .dropCurrent) {
      await oldTaskStarted.open()
      await oldTaskGate.wait()
      await oldOperationFinished.open()
    }

    await oldTaskStarted.wait()

    let replacementTask = manager.task(label: "replacement", key: key, mode: .dropCurrent) {
      await replacementTaskStarted.open()
      await replacementTaskGate.wait()
    }

    await replacementTaskStarted.wait()

    let queuedTask = manager.task(label: "queued", key: key, mode: .waitInCurrent) {
      didStartQueuedTask.value = true
    }

    await oldTaskGate.open()
    await oldOperationFinished.wait()

    await expectCancellation(from: oldTask)

    let didStartBeforeReplacementFinished = await waitUntil(timeoutMilliseconds: 250) {
      didStartQueuedTask.value
    }
    #expect(didStartBeforeReplacementFinished == false)

    await replacementTaskGate.open()

    let didStartAfterReplacementFinished = await waitUntil {
      didStartQueuedTask.value
    }
    #expect(didStartAfterReplacementFinished)

    do {
      _ = try await replacementTask.value
      _ = try await queuedTask.value
    } catch {
      Issue.record("Expected the current queue to finish, received \(error)")
    }
  }

  @Test func invalidatingUnstartedQueuedTaskCompletesWithCancellationError() async {
    let manager = TaskManager()
    let key = TaskKey("queued-invalidation")
    let oldTaskGate = NonCooperativeGate()
    let replacementTaskGate = NonCooperativeGate()

    let oldTaskStarted = NonCooperativeGate()
    let oldTask = manager.task(label: "old", key: key, mode: .dropCurrent) {
      await oldTaskStarted.open()
      await oldTaskGate.wait()
    }

    await oldTaskStarted.wait()

    let didStartQueuedTask = UnfairLockAtomic(false)
    let queuedTask = manager.task(label: "queued", key: key, mode: .waitInCurrent) {
      didStartQueuedTask.value = true
    }

    let queuedTaskOutcome = UnfairLockAtomic<Result<Void, Error>?>(nil)
    let queuedTaskObserver = Task {
      do {
        _ = try await queuedTask.value
        queuedTaskOutcome.value = .success(())
      } catch {
        queuedTaskOutcome.value = .failure(error)
      }
    }

    let replacementTask = manager.task(label: "replacement", key: key, mode: .dropCurrent) {
      await replacementTaskGate.wait()
    }

    let didFinishQueuedTask = await waitUntil {
      queuedTaskOutcome.value != nil
    }
    #expect(didFinishQueuedTask)
    #expect(didStartQueuedTask.value == false)

    switch queuedTaskOutcome.value {
    case .failure(let error) where error is CancellationError:
      break
    case .failure(let error):
      Issue.record("Expected CancellationError, received \(error)")
    case .success:
      Issue.record("Expected the invalidated queued task to fail")
    case nil:
      Issue.record("Expected the invalidated queued task to finish")
    }

    await oldTaskGate.open()
    await replacementTaskGate.open()

    await expectCancellation(from: oldTask)
    _ = try? await replacementTask.value
    queuedTaskObserver.cancel()
  }
}

private func expectCancellation<Success>(from task: Task<Success, Error>) async {
  do {
    _ = try await task.value
    Issue.record("Expected the task to throw CancellationError")
  } catch is CancellationError {
  } catch {
    Issue.record("Expected CancellationError, received \(error)")
  }
}

private func waitUntil(
  timeoutMilliseconds: Int = 1_000,
  condition: @escaping @Sendable () -> Bool
) async -> Bool {
  for _ in 0..<timeoutMilliseconds / 10 {
    guard condition() == false else { return true }
    try? await Task.sleep(nanoseconds: 10_000_000)
  }

  return condition()
}

/**
 A manually opened gate that deliberately ignores cancellation while suspended.

 Tests use it to model work that keeps running after its task receives a cancellation request.
 */
private actor NonCooperativeGate {

  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    guard isOpen == false else { return }

    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }

  func open() {
    isOpen = true

    let pendingWaiters = waiters
    waiters.removeAll()

    for waiter in pendingWaiters {
      waiter.resume()
    }
  }
}
