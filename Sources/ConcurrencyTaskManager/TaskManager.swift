import Foundation
import os.lock

public protocol TaskKeyType {

}

/**
 
 ```swift
 enum MyRequestTask: TaskKeyType {}
 let key = TaskKey(MyRequestTask.self)
 ```
 
 */
public struct TaskKey: Hashable, Sendable, ExpressibleByStringLiteral {
  
  public typealias StringLiteralType = String

  private enum Node: Hashable, @unchecked Sendable {
    case int(Int)
    case int64(Int64)
    case string(String)
    case boolean(Bool)
    case type(ObjectIdentifier)
    case anyHashable(AnyHashable)
  }

  private var nodes: Set<Node>

  public init<Key: TaskKeyType>(_ key: Key.Type) {
    self.nodes = .init(arrayLiteral: .type(.init(Key.self)))
  }

  public init(_ hashableItem: some Hashable & Sendable) {
    self.nodes = .init(arrayLiteral: .anyHashable(hashableItem))
  }

  public init(_ value: Int64) {
    self.nodes = .init(arrayLiteral: .int64(value))
  }

  public init(_ value: Bool) {
    self.nodes = .init(arrayLiteral: .boolean(value))
  }

  public init(_ value: Int) {
    self.nodes = .init(arrayLiteral: .int(value))
  }

  public init(_ customString: String) {
    self.nodes = .init(arrayLiteral: .string(customString))
  }

  public init(stringLiteral customString: String) {
    self.nodes = .init(arrayLiteral: .string(customString))
  }

  /**
   Make new distinct key with others.
   Note that ignores the given key if it's already included in the current.
   */
  public func combined(_ other: TaskKey) -> Self {
    var new = self
    new.nodes.formUnion(other.nodes)
    return new
  }

  /// Make with a new unique identifier
  public static func distinct() -> Self {
    .init(UUID().uuidString)
  }
  
  /// Makes a key with the file, line, and column number.
  public static func code(
    _ file: StaticString =  #fileID,
    _ line: UInt = #line,
    _ column: UInt = #column    
  ) -> Self {
    .init(stringLiteral: "\(file):\(line):\(column)")
  }

}

/**
 A class that manages tasks by specified keys.
 It enqueues a given task into a separated queue by key.
 Consumers can specify how to handle the current task as dropping it or waiting for it.
 */
public final class TaskManager: Sendable {

  public struct Configuration: Sendable {

    public init() {

    }
  }

  public enum Mode: Sendable {
    /**
     Cancels the current running task then start a new task.
     */
    case dropCurrent
    /**
     Waits the current task finished then start a new task.
     */
    case waitInCurrent
  }

  private struct State: Sendable {
    var isRunning: Bool = true
    var queues: [TaskKey: TaskNode] = [:]
  }

  private let state: OSAllocatedUnfairLock<State>

  public var isRunning: Bool {
    get {
      state.withLock { $0.isRunning }
    }
    set {
      state.withLock { state in
        state.isRunning = newValue
        if newValue {
          self.resume(state: &state)
        }
      }
    }
  }

  /**
   Set the task manager is running or not.
   If false, new task will not run until the isRunning is true.
   */
  public func setIsRunning(_ isRunning: Bool) {
    self.isRunning = isRunning
  }

  // MARK: Lifecycle

  public init(configuration: Configuration = .init()) {
    self.configuration = configuration
    self.state = OSAllocatedUnfairLock(initialState: State())
  }

  deinit {
  }

  // MARK: Public

  public let configuration: Configuration

  /**
   Returns a Boolean value that indicates whether the task for given key is currently running.
   */
  public func isRunning(for key: TaskKey) -> Bool {
    return state.withLock { $0.queues[key] != nil }
  }
  
  /// Registers an asynchronous operation
  ///
  /// Task's Error may be ``CancellationError``
  /// - Parameters:
  ///   - label: String value for debugging
  ///   - key: ``TaskKey`` value takes associated operations. It creates queues for each key.
  ///   - mode: Mode tells the queue how controls the given new operation. to run immediately with drop all current operation or wait all them.
  ///   - priority:
  ///   - action:
  /// - Returns: An Task to track the operation's completion.
  @discardableResult
  public func task<Return>(
    label: String = "",
    key: TaskKey,
    mode: Mode,
    priority: TaskPriority = .userInitiated,
    @_inheritActorContext _ operation: @Sendable @escaping @isolated(any) () async throws -> Return
  ) -> Task<Return, Error> {

    let extendedContinuation: AutoReleaseContinuationBox<Return> = .init(nil)

    let referenceTask = Task { [weak extendedContinuation] in
      return try await withUnsafeThrowingContinuation{ (continuation: UnsafeContinuation<Return, Error>) in
        extendedContinuation?.setContinuation(continuation)
      }
    }

    let newNode = TaskNode(label: label) { [weak self] node in

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

      // connecting to the next if presents

      guard let self = self else { return }
      
      self.loopback(
        key: key,
        completedNode: node
      )

    }

    state.withLock { state in
      switch mode {
      case .dropCurrent:

        state.queues[key]?.forEach {
          $0.invalidate()
        }

        state.queues[key] = newNode
        if state.isRunning {
          newNode.activate()
        }

      case .waitInCurrent:

        if let head = state.queues[key] {
          head.endpoint().addNext(newNode)
        } else {
          state.queues[key] = newNode
          if state.isRunning {
            newNode.activate()
          }
        }

      }
    }

    return referenceTask
    
  }

  public func taskDetached<Return>(
    label: String = "",
    key: TaskKey,
    mode: Mode,
    priority: TaskPriority = .userInitiated,
    _ action: @Sendable @escaping () async throws -> Return
  ) -> Task<Return, Error> {
    task(label: label, key: key, mode: mode, priority: priority, action)
  }

  /**
   Cancels tasks for the specified key.
   */
  public func cancel(key: TaskKey) {
    state.withLock { state in
      if let head = state.queues[key] {
        head.forEach { node in
          node.invalidate()
        }
        state.queues.removeValue(forKey: key)
      }
    }
  }

  /**
   Cancells all tasks managed in this manager.
   */
  public func cancelAll() {
    state.withLock { state in
      for head in state.queues.values {
        head.forEach { node in
          node.invalidate()
        }
      }

      state.queues.removeAll()
    }
  }

  private func loopback(key: TaskKey, completedNode: TaskNode) {
    state.withLock { state in
      if let headNode = state.queues[key] {

        let nextNode = headNode.state.withLock { $0.next }
        if let nextNode = nextNode {
          // drop headNode, set nextNode as head
          state.queues[key] = nextNode

          if state.isRunning {
            nextNode.activate()
          }
        } else {
          if headNode == completedNode {
            state.queues.removeValue(forKey: key)
          }
        }
      } else {
        // there is no head node, do nothing
      }

      Log.debug(.taskManager, state.queues)
    }
  }

  private func resume(state: inout State) {
    for (_, element) in state.queues {
      element.activate()
    }
  }

}
