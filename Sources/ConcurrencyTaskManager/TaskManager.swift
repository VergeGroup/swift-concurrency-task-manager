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
 Each key has its own queue. The mode decides how to handle a submission for an occupied key.
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

    /// Discards the new operation if the key already has running or queued work.
    ///
    /// The returned task is cancelled and its value throws `CancellationError`.
    case dropIfBusy
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
  /// Checks cancellation before invoking the operation. Once started, the operation
  /// must cooperate with cancellation across its own suspension points.
  /// Task's Error may be ``CancellationError``
  /// - Parameters:
  ///   - label: String value for debugging
  ///   - key: ``TaskKey`` value takes associated operations. It creates queues for each key.
  ///   - mode: How to handle a submission when the key has running or queued work.
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
    let continuationRegistration = TaskResultContinuationRegistration(box: extendedContinuation)

    let referenceTask = Task { [continuationRegistration] in
      return try await withUnsafeThrowingContinuation { continuation in
        continuationRegistration.setContinuation(continuation)
      }
    }

    let newNode = TaskNode(
      label: label,
      onInvalidation: {
        referenceTask.cancel()
        extendedContinuation.resume(throwing: CancellationError())
      }
    ) { [weak self] node in

      await withTaskCancellationHandler {
        let result: Result<Return, Error>
        do {
          result = .success(try await Self.performOperation(operation, isolation: operation.isolation))
        } catch {
          result = .failure(error)
        }

        // Release the queue slot before a caller can submit again after awaiting value.
        self?.loopback(key: key, completedNode: node)

        if Task.isCancelled {
          extendedContinuation.resume(throwing: CancellationError())
        } else {
          extendedContinuation.resume(with: result)
        }

      } onCancel: {
        referenceTask.cancel()
      }

    }

    state.withLock { state in
      if let head = state.queues[key] {
        switch mode {
        case .dropCurrent:
          head.forEach { $0.invalidate() }
        case .waitInCurrent:
          head.endpoint().addNext(newNode)
          return
        case .dropIfBusy:
          newNode.invalidate()
          return
        }
      }

      state.queues[key] = newNode
      if state.isRunning {
        newNode.activate()
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

  /// Checks on the operation's actor after any executor hop, immediately before invocation.
  private static func performOperation<Return: Sendable>(
    _ operation: @Sendable @isolated(any) () async throws -> Return,
    isolation: isolated (any Actor)?
  ) async throws -> Return {
    try Task.checkCancellation()
    return try await operation()
  }

  private func loopback(key: TaskKey, completedNode: TaskNode) {
    state.withLock { state in
      guard let headNode = state.queues[key], headNode == completedNode else { return }

      if let nextNode = headNode.state.withLock({ $0.next }) {
        // drop headNode, set nextNode as head
        state.queues[key] = nextNode

        if state.isRunning {
          nextNode.activate()
        }
      } else {
        state.queues.removeValue(forKey: key)
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

/// Keeps a completion box alive only until a caller-facing task registers its continuation.
private final class TaskResultContinuationRegistration<T>: @unchecked Sendable {

  private let lock = NSLock()
  private var box: AutoReleaseContinuationBox<T>?

  init(box: AutoReleaseContinuationBox<T>) {
    self.box = box
  }

  func setContinuation(_ continuation: UnsafeContinuation<T, Error>) {
    lock.lock()
    let box = self.box
    self.box = nil
    lock.unlock()

    box?.setContinuation(continuation)
  }
}
