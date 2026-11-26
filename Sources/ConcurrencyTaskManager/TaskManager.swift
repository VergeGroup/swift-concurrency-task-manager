import DequeModule
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
    var queues: [TaskKey: Deque<TaskNode>] = [:]
    var unfinishedNodes: [UUID: TaskNode] = [:]

    mutating func invalidate(_ queue: Deque<TaskNode>) {
      for node in queue {
        if node.invalidate() {
          unfinishedNodes.removeValue(forKey: node.id)
        }
      }
    }

    // Return the queue so captured values can deinitialize outside the manager lock.
    mutating func removeQueue(for key: TaskKey) -> Deque<TaskNode>? {
      guard let queue = queues.removeValue(forKey: key) else { return nil }
      invalidate(queue)
      return queue
    }
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

  /// Waits for the unfinished operations registered when this call takes its snapshot.
  ///
  /// This includes queued operations across all keys and operations still finishing after
  /// cancellation. Operations invalidated before invocation count as complete immediately.
  /// Later registrations are left for subsequent calls.
  ///
  /// Cancellation of the caller leaves both the wait and the managed operations running.
  /// Use the individual task handles to retrieve results and errors.
  ///
  /// Call from outside this manager's operations to avoid waiting for the calling
  /// operation itself. The caller controls admission and resumption of paused work.
  public func waitForAll() async {
    let unfinishedNodes = state.withLock { Array($0.unfinishedNodes.values) }
    for node in unfinishedNodes {
      await node.waitForCompletion()
    }
  }
  
  /// Registers an asynchronous operation
  ///
  /// Checks cancellation before invoking the operation. Once started, the operation
  /// must cooperate with cancellation across its own suspension points.
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
      },
      onCompletion: { [weak self] node in
        self?.operationDidFinish(key: key, completedNode: node)
      }
    ) { node in

      await withTaskCancellationHandler {
        do {
          let result = try await node.performOperation(operation, isolation: operation.isolation)

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
    }

    let removedQueue = state.withLock { state in
      let removedQueue: Deque<TaskNode>?
      switch mode {
      case .dropCurrent:
        removedQueue = state.removeQueue(for: key)
      case .waitInCurrent:
        removedQueue = nil
      }

      state.unfinishedNodes[newNode.id] = newNode
      state.queues[key, default: []].append(newNode)
      if state.isRunning, state.queues[key]?.count == 1 {
        newNode.activate()
      }
      return removedQueue
    }
    withExtendedLifetime(removedQueue) {}

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
    let removedQueue = state.withLock { $0.removeQueue(for: key) }
    withExtendedLifetime(removedQueue) {}
  }

  /**
   Cancells all tasks managed in this manager.
   */
  public func cancelAll() {
    let removedQueues = state.withLock { state in
      let queues = state.queues
      state.queues.removeAll()
      for queue in queues.values {
        state.invalidate(queue)
      }
      return queues
    }
    withExtendedLifetime(removedQueues) {}
  }

  private func operationDidFinish(key: TaskKey, completedNode: TaskNode) {
    state.withLock { state in
      state.unfinishedNodes.removeValue(forKey: completedNode.id)
      guard state.queues[key]?.first == completedNode else { return }
      _ = state.queues[key]?.popFirst()
      if let nextNode = state.queues[key]?.first {
        if state.isRunning {
          nextNode.activate()
        }
      } else {
        state.queues.removeValue(forKey: key)
      }

      Log.debug(.taskManager, "completed \(completedNode)")
    }
  }

  private func resume(state: inout State) {
    for queue in state.queues.values {
      queue.first?.activate()
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
