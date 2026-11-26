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
  }

  private struct State: Sendable {
    var flags: StateFlags = []
    var anyTask: Task<Void, Error>?
    var continuations: [CheckedContinuation<Void, Never>] = []
  }

  /// Completes the caller-facing task when this node is invalidated before activation.
  private let onInvalidation: @Sendable () -> Void

  private let taskFactory: @Sendable (TaskNode) async -> Void
  private let label: String
  let id: UUID
  private let state: OSAllocatedUnfairLock<State>

  init(
    label: String = "",
    onInvalidation: @escaping @Sendable () -> Void = {},
    @_inheritActorContext taskFactory: @escaping @Sendable @isolated(any) (TaskNode) async -> Void
  ) {
    self.label = label
    self.id = UUID()
    self.onInvalidation = onInvalidation
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

        stateRef.withLock { state in
          state.flags.insert(.finished)
          for continuation in state.continuations {
            continuation.resume()
          }
          state.continuations.removeAll()
        }
      }
    }
  }

  func invalidate() {
    let invalidation = state.withLock { state -> (Task<Void, Error>?, [CheckedContinuation<Void, Never>])? in
      guard state.flags.contains(.invalidated) == false else { return nil }

      Log.debug(.taskNode, "invalidated \(label) <\(self.id)>")
      state.flags.insert(.invalidated)
      let continuations = state.continuations
      state.continuations.removeAll()
      return (state.anyTask, continuations)
    }

    guard let (task, continuations) = invalidation else { return }

    for continuation in continuations {
      continuation.resume()
    }

    if let task {
      task.cancel()
    } else {
      onInvalidation()
    }
  }

  func wait() async {
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      state.withLock { state in
        if state.flags.contains(.finished) || state.flags.contains(.invalidated) {
          c.resume()
        } else {
          state.continuations.append(c)
        }
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
