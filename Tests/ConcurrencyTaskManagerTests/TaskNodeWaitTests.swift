@testable import ConcurrencyTaskManager
import Testing

struct TaskNodeWaitTests {

  @Test func waitCompletesAfterOperationReturns() async {
    let operationFinished = UnfairLockAtomic(false)
    let node = TaskNode(label: "test-wait") { node in
      do {
        try await node.performOperation({
          operationFinished.value = true
        }, isolation: nil)
      } catch {
        Issue.record("Expected the operation to succeed, received \(error)")
      }
    }

    node.activate()
    await node.waitForCompletion()
    #expect(operationFinished.value)
  }

  @Test func waitCompletesAfterInvalidationBeforeActivation() async {
    let node = TaskNode(label: "invalidated-task") { _ in
      Issue.record("An invalidated queued node must not run")
    }

    #expect(node.invalidate())
    node.activate()
    await node.waitForCompletion()
  }
}
