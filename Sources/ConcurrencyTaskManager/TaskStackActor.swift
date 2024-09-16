import DequeModule
import Foundation
@preconcurrency import Combine

public actor TaskStackActor {

  private struct State {
    var waitingCount: Int = 0
    var executingCount: Int = 0

    mutating func update(waitingCount: Int, executingCount: Int) {
      self.waitingCount = waitingCount
      self.executingCount = executingCount
    }
  }

  private var stack: Deque<TaskNode> = .init()
  private var executings: ContiguousArray<TaskNode> = .init()

  public private(set) var maxConcurrentTaskCount: Int

  private var currentExecutingTaskCount: Int = 0

  @Published private var state: State = .init()

  public init(maxConcurrentTaskCount: Int) {
    self.maxConcurrentTaskCount = maxConcurrentTaskCount
  }

  deinit {

  }

  @discardableResult
  public func addTask<Return>(
    label: String = "",
    priority: TaskPriority? = nil,
    operation: @escaping @Sendable () async throws -> Return
  ) -> Task<Return, Error> {

    let extendedContinuation: AutoReleaseContinuationBox<Return> = .init(nil)

    let referenceTask = Task { [weak extendedContinuation] in
      return try await withUnsafeThrowingContinuation{ (continuation: UnsafeContinuation<Return, Error>) in
        extendedContinuation?.setContinuation(continuation)
      }
    }

    let newNode = TaskNode(label: label) { [weak self] box in

      // Run the operation

      await withTaskCancellationHandler {
        do {
          let result = try await operation()

          guard Task.isCancelled == false else {
            extendedContinuation.resume(throwing: CancellationError())
            return
          }

          extendedContinuation.resume(returning: result)

        } catch {

          guard Task.isCancelled == false else {
            extendedContinuation.resume(throwing: CancellationError())
            return
          }

          extendedContinuation.resume(throwing: error)

        }
      } onCancel: {
        referenceTask.cancel()
      }

      await self?.decrement()

      // connecting to the next if presents

      if let node = box.value {
        await self?.processForCompletion(taskNode: node)
      }

      await self?.drain()

    }

    stack.prepend(newNode)

    drain()

    return referenceTask
  }

  /**
   Waits until the all enqueued are processed.
   Including added items while processing.
   */
  public func waitUntilAllItemProcessed() async {

    let stream = AsyncStream<State> { continuation in

      let cancellable = $state.sink { state in
        continuation.yield(state)
      }

      continuation.onTermination = { _ in        
        cancellable.cancel()
      }

    }

    for await state in stream {
      if state.executingCount == 0 && state.waitingCount == 0 {
        break
      }
    }

  }

  private func increment() {
    currentExecutingTaskCount += 1
  }

  private func decrement() {
    currentExecutingTaskCount -= 1

    state.update(waitingCount: stack.count, executingCount: currentExecutingTaskCount)
  }

  private func processForCompletion(
    taskNode: sending TaskNode
  ) {
    executings.removeAll { $0 === taskNode }
  }

  private func drain() {

    guard stack.isEmpty == false else {
      return
    }

    while currentExecutingTaskCount < maxConcurrentTaskCount {
      guard let node = stack.popFirst() else {
        return
      }
      executings.append(node)
      increment()

      state.update(waitingCount: stack.count, executingCount: currentExecutingTaskCount)

      node.activate()
    }
  }

}
