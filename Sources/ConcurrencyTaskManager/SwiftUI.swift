import SwiftUI

@propertyWrapper
public struct LocalTask: DynamicProperty {

  @StateObject private var box: Box = .init()

  @MainActor
  @preconcurrency
  public var wrappedValue: TaskManager {
    box.taskManager
  }

  public var projectedValue: LocalTask {
    self
  }

  public init(projectedValue: LocalTask) {
    self = projectedValue
  }

  public init() {

  }

  private final class Box: ObservableObject {
    let taskManager = TaskManager()

    deinit {
      taskManager.cancelAll()
    }
  }
}

extension TaskManager {
  /// SwiftUI-specific task method with isRunning binding support
  @discardableResult
  public func taskWithBinding<Return>(
    isRunning: Binding<Bool>,
    label: String = "",
    key: TaskKey,
    mode: Mode,
    priority: TaskPriority = .userInitiated,
    @_inheritActorContext _ operation: @Sendable @escaping () async throws -> Return
  ) -> Task<Return, Error> where Return: Sendable {
    isRunning.wrappedValue = true
    let originalTask = self.task(
      label: label,
      key: key,
      mode: mode,
      priority: priority,
      operation
    )

    return Task {
      do {
        let result = try await originalTask.value
        await MainActor.run {
          isRunning.wrappedValue = false
        }
        return result
      } catch {
        await MainActor.run {
          isRunning.wrappedValue = false
        }
        throw error
      }
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
