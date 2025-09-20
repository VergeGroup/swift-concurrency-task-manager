import Foundation

final class AutoReleaseContinuationBox<T>: @unchecked Sendable {

  private let lock = NSRecursiveLock()

  private var continuation: UnsafeContinuation<T, Error>?
  private var wasConsumed: Bool = false

  init(_ value: UnsafeContinuation<T, Error>?) {
    self.continuation = value
  }

  deinit {
    resume(throwing: CancellationError())
  }

  func setContinuation(_ continuation: UnsafeContinuation<T, Error>?) {
    lock.lock()
    defer {
      lock.unlock()
    }

    self.continuation = continuation
  }

  func resume(throwing error: sending Error) {
    lock.lock()
    defer {
      lock.unlock()
    }
    guard wasConsumed == false else {
      return
    }
    wasConsumed = true
    continuation?.resume(throwing: error)
  }

  func resume(returning value: sending T) {
    lock.lock()
    defer {
      lock.unlock()
    }
    guard wasConsumed == false else {
      return
    }
    wasConsumed = true
    continuation?.resume(returning: value)
  }

}