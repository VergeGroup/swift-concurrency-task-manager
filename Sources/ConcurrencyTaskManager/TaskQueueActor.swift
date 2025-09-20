import Foundation
@preconcurrency import Combine

public actor TaskQueueActor {

  public var hasTask: Bool {
    head != nil
  }

  @Published private var head: TaskNode?

  private var isTaskProcessing = false

  public let label: String

  public init(label: String = "") {
    Log.debug(.taskQueue, "Init Queue: \(label)")
    self.label = label
  }

  deinit {

  }

  public func cancelAllTasks() {
    Log.debug(.taskQueue, "Cancell all task")
    if let head {
      sequence(first: head, next: \.next).forEach {
        $0.invalidate()
      }
    }
    self.head = nil
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
      
      await self?.advance(box: box)
      
    }

    if let head {
      head.endpoint().addNext(newNode)
      Log.debug(.taskQueue, "Add \(label) currentHead: \(head as Any)")
    } else {
      Log.debug(.taskQueue, "Add \(label) as head")
      self.head = newNode
      newNode.activate()
    }

    return referenceTask
  }

  /**
   Waits until the current enqueued items are all processed
   */
  public func waitUntilAllItemProcessedInCurrent() async {
    await head?.endpoint().wait()
  }
  
  /**
   Waits until the all enqueued are processed.
   Including added items while processing.
   */
  public func waitUntilAllItemProcessed() async {
    
    let stream = AsyncStream<TaskNode?> { continuation in
      
      let cancellable = $head.sink { state in
        continuation.yield(state)
      }
      
      continuation.onTermination = { _ in
        cancellable.cancel()
      }
      
    }
    
    for await node in stream {
      if let node {
        await node.wait()
      } else {
        break
      }
    }
    
  }
  
  func advance(box: sending TaskNode.WeakBox<TaskNode>) {
    guard let node = box.value else { return }
    if let next = node.next {
      self.head = next
      next.activate()
    } else {
      if self.head === node {
        self.head = nil
      }
    }
  }

}

