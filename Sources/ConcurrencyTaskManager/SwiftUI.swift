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
