import SwiftUI

@propertyWrapper
public struct LocalTask: DynamicProperty {
  
  @StateObject private var box: Box = .init(wrapper: .init(taskManager: .init()))
  
  @MainActor
  @preconcurrency
  public var wrappedValue: LocalTaskWrapper {
    box.wrapper
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
    let wrapper: LocalTaskWrapper

    init(wrapper: LocalTaskWrapper) {
      self.wrapper = wrapper
    }
    
    deinit {
      wrapper.cancelAllTasks()
    }
  }
}

public struct LocalTaskWrapper: Sendable {
  
  private let taskManager: TaskManager

  public init(taskManager: TaskManager) {
    self.taskManager = taskManager
  }
  
  @discardableResult
  public func task<Return>(
    isRunning: Binding<Bool>? = nil,
    label: String = "",
    key: TaskKey,
    mode: TaskManager.Mode,
    priority: TaskPriority = .userInitiated,
    @_inheritActorContext _ operation: @Sendable @escaping () async throws -> Return
  ) -> Task<Return, Error> {  
    isRunning?.wrappedValue = true
    return Task { [taskManager] in
      
      let result = try await taskManager
        .task(
          label: label,
          key: key,
          mode: mode,
          priority: priority,
          operation
        )
        .value
      
      Task { @MainActor in
        isRunning?.wrappedValue = false
      }
      
      return result
    }
  }
  
  public func cancelTask(key: TaskKey) {
    taskManager.cancel(key: key)
  }

  public func cancelAllTasks() {
    taskManager.cancelAll()
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
