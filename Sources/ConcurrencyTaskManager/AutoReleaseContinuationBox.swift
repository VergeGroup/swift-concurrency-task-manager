import Foundation

/**
 A thread-safe, one-shot bridge between a deferred operation and its caller-facing task.

 A result may arrive before the caller-facing task installs its continuation. In that case,
 the box retains the result and delivers it when the continuation is registered.
 */
final class AutoReleaseContinuationBox<T>: @unchecked Sendable {

  private enum State {
    case pending
    case waiting(UnsafeContinuation<T, Error>)
    case buffered(Result<T, Error>)
    case completed
  }

  private let lock = NSRecursiveLock()

  private var state: State

  init(_ value: UnsafeContinuation<T, Error>?) {
    if let value {
      self.state = .waiting(value)
    } else {
      self.state = .pending
    }
  }

  deinit {
    resume(throwing: CancellationError())
  }

  func setContinuation(_ continuation: UnsafeContinuation<T, Error>?) {
    guard let continuation else { return }

    lock.lock()

    switch state {
    case .pending:
      state = .waiting(continuation)
      lock.unlock()

    case .waiting:
      lock.unlock()
      assertionFailure("Continuation is already registered.")

    case .buffered(let result):
      state = .completed
      lock.unlock()
      continuation.resume(with: result)

    case .completed:
      lock.unlock()
      assertionFailure("Continuation is already completed.")
    }
  }

  func resume(throwing error: sending Error) {
    resume(with: .failure(error))
  }

  func resume(returning value: sending T) {
    resume(with: .success(value))
  }

  private func resume(with result: sending Result<T, Error>) {
    lock.lock()

    switch state {
    case .pending:
      state = .buffered(result)
      lock.unlock()

    case .waiting(let continuation):
      state = .completed
      lock.unlock()
      continuation.resume(with: result)

    case .buffered, .completed:
      lock.unlock()
    }
  }

}
