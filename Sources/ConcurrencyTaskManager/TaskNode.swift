import Foundation
import os.lock

struct TaskNode: CustomStringConvertible, Sendable, Equatable {

  private struct StateFlags: OptionSet, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    static let activated   = StateFlags(rawValue: 1 << 0)
    static let finished    = StateFlags(rawValue: 1 << 1)
    static let invalidated = StateFlags(rawValue: 1 << 2)
    static let started     = StateFlags(rawValue: 1 << 3)
  }

  private struct State: Sendable {
    var flags: StateFlags = []
    var anyTask: Task<Void, Error>?
    var continuations: [CheckedContinuation<Void, Never>] = []

    mutating func finish() -> [CheckedContinuation<Void, Never>]? {
      guard flags.insert(.finished).inserted else { return nil }
      let waiters = continuations
      continuations.removeAll()
      return waiters
    }
  }

  /// Completes the caller-facing task when this node is invalidated before invocation.
  private let onInvalidation: @Sendable () -> Void
  private let onCompletion: @Sendable (TaskNode) -> Void

  private let taskFactory: @Sendable (TaskNode) async -> Void
  private let label: String
  let id: UUID
  private let state: OSAllocatedUnfairLock<State>

  init(
    label: String = "",
    onInvalidation: @escaping @Sendable () -> Void = {},
    onCompletion: @escaping @Sendable (TaskNode) -> Void = { _ in },
    @_inheritActorContext taskFactory: @escaping @Sendable @isolated(any) (TaskNode) async -> Void
  ) {
    self.label = label
    self.id = UUID()
    self.onInvalidation = onInvalidation
    self.onCompletion = onCompletion
    self.taskFactory = taskFactory
    self.state = OSAllocatedUnfairLock(initialState: State())
  }

  /// Starts the deferred task
  func activate() {
    state.withLock { state in
      guard state.flags.contains(.activated) == false else { return }
      guard state.flags.contains(.invalidated) == false else { return }
      guard state.anyTask == nil else { return }

      state.flags.insert(.activated)

      Log.debug(.taskNode, "activate: \(label) <\(self.id)>")

      state.anyTask = Task<Void, Error> { [stateRef = self.state, taskFactory = self.taskFactory] in

        await taskFactory(self)

        guard let waiters = stateRef.withLock({ $0.finish() }) else { return }
        self.onCompletion(self)
        for waiter in waiters {
          waiter.resume()
        }
      }
    }
  }

  /// Claims the operation on its own actor, after any executor hop.
  func performOperation<Return: Sendable>(
    _ operation: @Sendable @isolated(any) () async throws -> Return,
    isolation: isolated (any Actor)?
  ) async throws -> Return {
    try Task.checkCancellation()
    try state.withLock { state in
      guard state.flags.contains(.invalidated) == false else {
        throw CancellationError()
      }
      state.flags.insert(.started)
    }
    return try await operation()
  }

  /// Returns whether invalidation completed the node before the operation started.
  @discardableResult
  func invalidate() -> Bool {
    let invalidation = state.withLock { state
      -> (task: Task<Void, Error>?, waiters: [CheckedContinuation<Void, Never>]?)? in
      guard state.flags.contains(.invalidated) == false else { return nil }

      Log.debug(.taskNode, "invalidated \(label) <\(self.id)>")
      state.flags.insert(.invalidated)
      if state.flags.contains(.started) {
        return (state.anyTask, nil)
      }
      return (state.anyTask, state.finish())
    }

    guard let invalidation else { return false }
    invalidation.task?.cancel()
    guard let waiters = invalidation.waiters else { return false }

    onInvalidation()
    for waiter in waiters {
      waiter.resume()
    }
    return true
  }

  func waitForCompletion() async {
    await withCheckedContinuation { continuation in
      let alreadyFinished = state.withLock { state in
        guard state.flags.contains(.finished) == false else {
          return true
        }
        state.continuations.append(continuation)
        return false
      }
      if alreadyFinished {
        continuation.resume()
      }
    }
  }

  var description: String {
    "<\(id)>:\(label)"
  }

  static func == (lhs: TaskNode, rhs: TaskNode) -> Bool {
    return lhs.id == rhs.id
  }
}
