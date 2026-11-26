import ConcurrencyTaskManager
import Dispatch
import Testing

@Suite struct WaitForAllTests {

  private enum OperationError: Error {
    case failed
  }

  @Test func emptyManagerAndInvalidatedPausedWork() async {
    let manager = TaskManager()
    await manager.waitForAll()

    manager.setIsRunning(false)
    let task = manager.task(key: "paused", mode: .waitInCurrent) {
      Issue.record("An invalidated paused operation must not run")
    }

    manager.cancelAll()
    await manager.waitForAll()
    await expectCancellation(from: task)
  }

  @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
  @Test(arguments: [true, false]) @MainActor
  func invalidatingBeforeOperationEntryDoesNotWaitForItsActor(waitingBeforeCancellation: Bool) async {
    let manager = TaskManager()
    let key = TaskKey("actor-entry")
    let task = manager.task(key: key, mode: .dropCurrent) { @MainActor in
      Issue.record("An operation invalidated before actor entry must not run")
    }
    if waitingBeforeCancellation == false {
      manager.cancel(key: key)
    }

    let executor = WaiterExecutor()
    let waiterFinished = UnfairLockAtomic(false)
    let waiter = Task.detached(executorPreference: executor) {
      await manager.waitForAll()
      waiterFinished.value = true
    }

    // The operation's actor cannot run until this test suspends.
    executor.flushSubmittedJobsWithoutSuspending()
    if waitingBeforeCancellation {
      #expect(waiterFinished.value == false)
      manager.cancel(key: key)
      executor.flushSubmittedJobsWithoutSuspending()
    }
    #expect(waiterFinished.value)

    await waiter.value
    await expectCancellation(from: task)
  }

  @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
  @Test(arguments: [true, false])
  func waitsForSnapshotAcrossKeysAndQueuedWorkEvenWhenWaiterIsCancelled(queuedFinishesLast: Bool) async throws {
    let manager = TaskManager()
    let releaseHead = NonCooperativeGate()
    let releaseOtherKey = NonCooperativeGate()
    let releaseQueued = NonCooperativeGate()
    let releaseLater = NonCooperativeGate()
    let queuedStarted = NonCooperativeGate()
    let otherKeyFinished = UnfairLockAtomic(false)
    let queuedFinished = UnfairLockAtomic(false)
    let waiterFinished = UnfairLockAtomic(false)

    manager.task(key: "serial", mode: .waitInCurrent) {
      await releaseHead.wait()
    }
    let queued = manager.task(key: "serial", mode: .waitInCurrent) {
      defer { queuedFinished.value = true }
      await queuedStarted.open()
      await releaseQueued.wait()
      #expect(Task.isCancelled == false)
      throw OperationError.failed
    }
    let otherKey = manager.task(key: "other", mode: .waitInCurrent) {
      defer { otherKeyFinished.value = true }
      await releaseOtherKey.wait()
      #expect(Task.isCancelled == false)
      return 42
    }

    let executor = WaiterExecutor()
    let waiter = Task(executorPreference: executor) {
      await manager.waitForAll()
      #expect(otherKeyFinished.value)
      #expect(queuedFinished.value)
      waiterFinished.value = true
    }
    await executor.flushSubmittedJobs()
    #expect(waiterFinished.value == false)
    waiter.cancel()

    manager.task(key: "serial", mode: .waitInCurrent) {
      await releaseLater.wait()
    }

    await releaseHead.open()
    await queuedStarted.wait()
    if queuedFinishesLast {
      await releaseOtherKey.open()
      #expect(try await otherKey.value == 42)
    } else {
      await releaseQueued.open()
      _ = await queued.result
    }

    await executor.flushSubmittedJobs()
    #expect(waiterFinished.value == false)

    await releaseQueued.open()
    await releaseOtherKey.open()
    await #expect(throws: OperationError.failed) {
      try await queued.value
    }
    #expect(try await otherKey.value == 42)

    // Bound the check so a regression that includes the later registration can unwind.
    let returnedBeforeLaterWork = await waitUntil { waiterFinished.value }
    #expect(returnedBeforeLaterWork)
    await releaseLater.open()
    await waiter.value
    await manager.waitForAll()
  }

  enum Invalidation: CaseIterable {
    case key
    case all
    case replacement
  }

  @available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
  @Test(arguments: Invalidation.allCases)
  func waitsForCleanupOfOperationsRemovedFromTheQueue(_ invalidation: Invalidation) async throws {
    let manager = TaskManager()
    let key = TaskKey("removed")
    let started = NonCooperativeGate()
    let checkCancellation = NonCooperativeGate()
    let cleanupStarted = NonCooperativeGate()
    let releaseCleanup = NonCooperativeGate()
    let cleanupFinished = UnfairLockAtomic(false)
    let waiterFinished = UnfairLockAtomic(false)

    let task = manager.task(key: key, mode: .waitInCurrent) {
      defer { cleanupFinished.value = true }
      await started.open()
      await checkCancellation.wait()
      do {
        try Task.checkCancellation()
      } catch {
        await cleanupStarted.open()
        await releaseCleanup.wait()
        throw error
      }
    }
    await started.wait()

    let queued = manager.task(key: key, mode: .waitInCurrent) {
      Issue.record("An invalidated queued operation must not run")
    }

    switch invalidation {
    case .key:
      manager.cancel(key: key)
    case .all:
      manager.cancelAll()
    case .replacement:
      let replacement = manager.task(key: key, mode: .dropCurrent) {}
      try await replacement.value
    }

    await checkCancellation.open()
    await cleanupStarted.wait()
    await expectCancellation(from: queued)

    let executor = WaiterExecutor()
    let waiter = Task(executorPreference: executor) {
      await manager.waitForAll()
      #expect(cleanupFinished.value)
      waiterFinished.value = true
    }
    await executor.flushSubmittedJobs()
    #expect(waiterFinished.value == false)

    await releaseCleanup.open()
    await waiter.value
    await expectCancellation(from: task)
    await manager.waitForAll()
  }
}

/// Gives tests a point after a waiter has entered the API and suspended.
@available(macOS 15, iOS 18, tvOS 18, watchOS 11, *)
private final class WaiterExecutor: TaskExecutor {

  private let queue = DispatchQueue(label: "WaitForAllTests.waiter")

  func enqueue(_ job: consuming ExecutorJob) {
    let job = UnownedJob(job)
    queue.async {
      job.runSynchronously(on: self.asUnownedTaskExecutor())
    }
  }

  func flushSubmittedJobs() async {
    await withCheckedContinuation { continuation in
      queue.async {
        continuation.resume()
      }
    }
  }

  func flushSubmittedJobsWithoutSuspending() {
    queue.sync {}
  }
}
