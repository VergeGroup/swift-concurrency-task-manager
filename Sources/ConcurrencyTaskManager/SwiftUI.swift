import SwiftUI

@propertyWrapper
public struct TaskManager: DynamicProperty {
  
  @StateObject private var box: Box = .init(wrapper: .init(taskManager: .init()))
  
  @MainActor 
  @preconcurrency 
  public var wrappedValue: TaskManagerActorWrapper {
    box.wrapper
  }
  
  public init() {

  }
  
  private final class Box: ObservableObject {
    let wrapper: TaskManagerActorWrapper
    
    init(wrapper: TaskManagerActorWrapper) {
      self.wrapper = wrapper
    }
    
    deinit {
      wrapper.cancelAllTasks()
    }
  }
}

public struct TaskManagerActorWrapper: Sendable {
  
  private let taskManager: TaskManagerActor
  
  public init(taskManager: TaskManagerActor) {
    self.taskManager = taskManager
  }
  
  @discardableResult
  public func task<Return>(
    isRunning: Binding<Bool>? = nil,
    label: String = "",
    key: TaskKey,
    mode: TaskManagerActor.Mode,
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
  
  public func cancelAllTasks() {
    Task {
      await taskManager.cancelAll()
    }
  }
}

#if DEBUG

private struct _View: View {
  
  @TaskManager var taskManager
    
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
