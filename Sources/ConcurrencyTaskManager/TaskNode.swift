import Foundation
import os.lock

/**
 structure of linked-list
 it has a node for the next task after this node.
 */
struct TaskNode: CustomStringConvertible, Sendable, Equatable {

  struct StateFlags: OptionSet, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    static let activated   = StateFlags(rawValue: 1 << 0)
    static let finished    = StateFlags(rawValue: 1 << 1)
    static let invalidated = StateFlags(rawValue: 1 << 2)
  }

  struct State: Sendable {
    var flags: StateFlags = []
    var anyTask: Task<Void, Error>?
    var next: TaskNode?
    var continuations: [CheckedContinuation<Void, Never>] = []
  }

  let taskFactory: @Sendable (TaskNode) async -> Void
  let label: String
  let id: UUID
  let state: OSAllocatedUnfairLock<State>

  init(
    label: String = "",
    @_inheritActorContext taskFactory: @escaping @Sendable @isolated(any) (TaskNode) async -> Void
  ) {
    self.label = label
    self.id = UUID()
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
    state.withLock { state in
      Log.debug(.taskNode, "invalidated \(label) <\(self.id)>")
      state.flags.insert(.invalidated)
      for continuation in state.continuations {
        continuation.resume()
      }
      state.continuations.removeAll()
      state.anyTask?.cancel()
    }
  }

  func addNext(_ node: TaskNode) {
    state.withLock { state in
      guard state.next == nil else {
        assertionFailure("next is already set.")
        return
      }
      state.next = node
    }
  }

  func endpoint() -> TaskNode {
    var current = self
    while let next = current.state.withLock({ $0.next }) {
      current = next
    }
    return current
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
    var chain: [String] = []
    var current: TaskNode? = self
    while let node = current {
      chain.append("<\(node.id)>:\(node.label)")
      current = node.state.withLock { $0.next }
    }
    return chain.joined(separator: " -> ")
  }

  func forEach(_ closure: (TaskNode) -> Void) {
    var current: TaskNode? = self
    while let node = current {
      closure(node)
      current = node.state.withLock { $0.next }
    }
  }

  static func == (lhs: TaskNode, rhs: TaskNode) -> Bool {
    return lhs.id == rhs.id
  }
}
