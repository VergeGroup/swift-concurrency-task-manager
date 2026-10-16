import SwiftUI

/// A property wrapper that owns a task manager in a SwiftUI view's state.
///
/// Declare a local task manager as a private property of a view to manage work
/// started by user interactions. Tasks with the same key follow the execution
/// mode you pass to ``TaskManager/task(label:key:mode:priority:_:)``:
///
/// ```swift
/// struct RefreshButton: View {
///   @LocalTask private var tasks
///   let refresh: @Sendable () async throws -> Void
///
///   var body: some View {
///     Button("Refresh") {
///       let refresh = refresh
///       tasks.task(key: "refresh", mode: .dropCurrent) {
///         try await refresh()
///       }
///     }
///   }
/// }
/// ```
///
/// SwiftUI preserves the manager across updates while the view's identity
/// remains the same. When the backing storage is released, it cancels all
/// running and queued tasks. Running operations must cooperate with cancellation,
/// for example by calling `Task.checkCancellation()` or a throwing sleep.
/// Cancellation follows the storage's lifetime, rather than `onDisappear`.
///
/// Keeping the projected wrapper, or capturing the enclosing view in an
/// operation, can extend the storage's lifetime. Capture only the dependencies
/// the operation needs, as the example does with `refresh`.
///
/// The manager doesn't publish changes to task execution. Store any progress
/// displayed by the view in separate observable state.
@propertyWrapper
public struct LocalTask: DynamicProperty {

  // The box owns the manager's lifetime; its contents don't drive view updates.
  @State private var box: Box = .init()

  /// The task manager associated with this view's state.
  ///
  /// Access the manager from the view's body or its action closures, after
  /// SwiftUI has installed the property in the view hierarchy.
  @MainActor
  @preconcurrency
  public var wrappedValue: TaskManager {
    box.taskManager
  }

  /// A wrapper that shares this property's backing storage.
  ///
  /// Access this value with the `$` prefix to pass the same local task manager
  /// to code that accepts a ``LocalTask`` projection.
  public var projectedValue: LocalTask {
    self
  }

  /// Creates a wrapper that shares an existing local task manager's storage.
  ///
  /// - Parameter projectedValue: The projection of another local task property.
  public init(projectedValue: LocalTask) {
    self = projectedValue
  }

  /// Creates a local task manager for SwiftUI to retain as part of a view's state.
  public init() {

  }

  /// Cancels managed work when the final owner releases this storage.
  ///
  /// Keeping cancellation here lets a caller retain the manager without
  /// extending the lifetime of the view's task storage.
  private final class Box {
    let taskManager = TaskManager()

    deinit {
      taskManager.cancelAll()
    }
  }
}

#if DEBUG

private struct _View: View {
  
  @LocalTask var taskManager
    
  var body: some View {
    Button("Start") {
      taskManager.task(key: .distinct(), mode: .dropCurrent) { 
        try await Task.sleep(nanoseconds: 1_000_000_000)        
        print("Task 1")
      }
    }
  }
  
}

#endif
