#if os(macOS)
import AppKit
import ConcurrencyTaskManager
import SwiftUI
import Testing

/// Exercises local task storage in an installed SwiftUI view hierarchy.
@MainActor
@Suite struct LocalTaskTests {

  @Test func viewUpdatesPreserveManagerAndQueuedWork() throws {
    var currentManager: TaskManager?
    let host = NSHostingView(rootView: LocalTaskProbe(revision: 0) {
      currentManager = $0
    })
    host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
    host.layoutSubtreeIfNeeded()

    let manager = try #require(currentManager)
    defer { manager.cancelAll() }
    manager.setIsRunning(false)
    let task = manager.task(key: "queued", mode: .waitInCurrent) {}

    currentManager = nil
    host.rootView = LocalTaskProbe(revision: 1) {
      currentManager = $0
    }
    host.layoutSubtreeIfNeeded()

    #expect(currentManager === manager)
    #expect(manager.isRunning(for: "queued"))
    #expect(!task.isCancelled)
  }

  @Test func releasingViewStorageCancelsRunningAndQueuedWork() async throws {
    var currentManager: TaskManager?
    var host: NSHostingView<LocalTaskProbe>? = autoreleasepool {
      let host = NSHostingView(rootView: LocalTaskProbe(revision: 0) {
        currentManager = $0
      })
      host.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
      host.layoutSubtreeIfNeeded()
      return host
    }

    // Retain the manager to verify that releasing the view's storage cancels work
    // independently of the manager's own lifetime.
    let manager = try #require(currentManager)
    defer { manager.cancelAll() }
    let didStartRunning = UnfairLockAtomic(false)
    let didStartQueued = UnfairLockAtomic(false)
    let running = manager.task(key: "work", mode: .waitInCurrent) {
      didStartRunning.value = true
      try await Task.sleep(for: .seconds(60))
    }
    let queued = manager.task(key: "work", mode: .waitInCurrent) {
      didStartQueued.value = true
    }

    let didStart = await waitUntil { didStartRunning.value }
    try #require(didStart)
    #expect(host != nil)
    host = nil

    let didCancel = await waitUntil { running.isCancelled && queued.isCancelled }
    try #require(didCancel)
    #expect(!manager.isRunning(for: "work"))
    #expect(!didStartQueued.value)
    await #expect(throws: CancellationError.self) { try await running.value }
    await #expect(throws: CancellationError.self) { try await queued.value }
  }

  /// Allows SwiftUI to finish deferred storage cleanup without an unbounded wait.
  private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<100 {
      if condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
  }
}

/// Reports the installed manager on each body evaluation without retaining its wrapper.
private struct LocalTaskProbe: View {
  @LocalTask private var tasks
  let revision: Int
  let report: (TaskManager) -> Void

  var body: some View {
    let _ = report(tasks)
    Text("\(revision)")
  }
}
#endif
