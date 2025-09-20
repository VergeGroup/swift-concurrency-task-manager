import Foundation
@preconcurrency import Combine

/**
 structure of linked-list
 it has a node for the next task after this node.
 */
final class TaskNode: CustomStringConvertible, @unchecked Sendable {

  struct WeakBox<T: AnyObject> {
    weak var value: T?
  }

  private struct State: Sendable {

    var isActivated: Bool = false
    var isFinished: Bool = false
    var isInvalidated: Bool = false

  }

  private var anyTask: _Verge_TaskType?

  let taskFactory: (sending WeakBox<TaskNode>) async -> Void

  private(set) var next: TaskNode?
  let label: String

  @Published private var state: State = .init()

  init(
    label: String = "",
    @_inheritActorContext taskFactory: @escaping @Sendable (sending WeakBox<TaskNode>) async -> Void
  ) {
    self.label = label
    self.taskFactory = taskFactory
  }

  /// Starts the deferred task
  func activate() {
    guard state.isActivated == false else { return }
    guard state.isInvalidated == false else { return }
    guard anyTask == nil else { return }

    state.isActivated = true

    Log.debug(.taskNode, "activate: \(label) <\(Unmanaged.passUnretained(self).toOpaque())>")

    self.anyTask = Task { [weak self] in
      await self?.taskFactory(.init(value: self))
      self?.state.isFinished = true
    }
  }

  func invalidate() {
    Log.debug(.taskNode, "invalidated \(label) <\(Unmanaged.passUnretained(self).toOpaque())>")
    state.isInvalidated = true
    anyTask?.cancel()
  }

  func addNext(_ node: TaskNode) {
    guard self.next == nil else {
      assertionFailure("next is already set.")
      return
    }
    self.next = node
  }

  func endpoint() -> TaskNode {
    sequence(first: self, next: \.next).compactMap { $0 }.last!
  }

  func wait() async {

    let stream = AsyncStream<State> { continuation in

      let cancellable = $state.sink { state in
        continuation.yield(state)
      }

      continuation.onTermination = { _ in
        cancellable.cancel()
      }

    }

    for await state in stream {
      if state.isInvalidated == true || state.isFinished == true {
        break
      }
    }

  }

  deinit {
    Log.debug(.taskNode, "Deinit: \(label) <\(Unmanaged.passUnretained(self).toOpaque())>")
  }

  var description: String {
    let chain = sequence(first: self, next: \.next).compactMap { $0 }.map {"<\(Unmanaged.passUnretained($0).toOpaque())>:\($0.label)" }.joined(separator: " -> ")
    return "\(chain)"
  }

  func forEach(_ closure: (TaskNode) -> Void) {
    sequence(first: self, next: \.next).forEach(closure)
  }
}