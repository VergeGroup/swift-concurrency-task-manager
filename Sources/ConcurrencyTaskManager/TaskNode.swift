import Foundation
import os.lock

/**
 structure of linked-list
 it has a node for the next task after this node.
 */
final class TaskNode: CustomStringConvertible, Sendable {

  struct WeakBox<T: AnyObject> {
    weak var value: T?
  }

  private struct State: OptionSet, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) {
      self.rawValue = rawValue
    }

    static let activated   = State(rawValue: 1 << 0)
    static let finished    = State(rawValue: 1 << 1)
    static let invalidated = State(rawValue: 1 << 2)
  }

  nonisolated(unsafe)
  private var anyTask: Task<Void, Error>?

  let taskFactory: @Sendable (WeakBox<TaskNode>) async -> Void

  nonisolated(unsafe)
  private(set) var next: TaskNode?
  
  let label: String

  nonisolated(unsafe)
  private var state: State = []
  
  nonisolated(unsafe)
  private var continuations: [CheckedContinuation<Void, Never>] = []
  
  private let lock = OSAllocatedUnfairLock()

  init(
    label: String = "",
    @_inheritActorContext taskFactory: @escaping @Sendable (WeakBox<TaskNode>) async -> Void
  ) {
    self.label = label
    self.taskFactory = taskFactory
  }

  /// Starts the deferred task
  func activate() {
    
    lock.lock()
    defer { lock.unlock() }
    
    guard state.contains(.activated) == false else { return }
    guard state.contains(.invalidated) == false else { return }
    guard anyTask == nil else { return }

    state.insert(.activated)

    Log.debug(.taskNode, "activate: \(label) <\(Unmanaged.passUnretained(self).toOpaque())>")

    self.anyTask = Task<Void, Error> { [weak self] in
      
      await self?.taskFactory(.init(value: self))
      
      guard let self = self else { return }
      
      self.state.insert(.finished)
      for continuation in self.continuations {
        continuation.resume()
      }
    }
  }

  func invalidate() {
    
    lock.lock()
    defer { lock.unlock() }
    
    Log.debug(.taskNode, "invalidated \(label) <\(Unmanaged.passUnretained(self).toOpaque())>")
    self.state.insert(.invalidated)
    for continuation in continuations {
      continuation.resume()
    }
    anyTask?.cancel()
  }

  func addNext(_ node: TaskNode) {
    
    lock.lock()
    defer { lock.unlock() }
    
    guard self.next == nil else {
      assertionFailure("next is already set.")
      return
    }
    self.next = node
  }

  func endpoint() -> TaskNode {
    return sequence(first: self, next: \.next).compactMap { $0 }.last!
  }

  func wait() async {
    
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      lock.lock()
      defer { lock.unlock() }
      continuations.append(c)
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
