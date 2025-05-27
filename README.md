# TaskManager - Swift Concurrency

## Overview

swift-concurrency supports structured concurrency but it also supports unstructured concurrency using Task API.
Task API runs immediately its work item. Although using closure can make deferred tasks.

TaskManager accepts work items to run in a serial queue isolated by the key.  
Passing key and mode (drop current items / wait in current items)

## Usage

This section describes the direct, programmatic use of `TaskManagerActor`. For managing tasks within non-SwiftUI contexts, or when you need more fine-grained control, you can interact with `TaskManagerActor` as shown below:

```swift

enum MyTask: TaskKeyType {}

// Assuming 'manager' is an instance of TaskManagerActor
// let manager = TaskManagerActor() // If creating a new one directly
// Or, if you have an existing TaskManager from SwiftUI's @TaskManager, 
// you'd typically use the wrappedValue for such direct calls, though less common.
let manager = TaskManagerActor() // For clarity in this non-SwiftUI example.

// this `await` is just for appending task item since TaskManager is Actor.
let ref = await manager.task(key: .init(MyTask.self), mode: .dropCurrent) {
  // work
}

// to wait the completion of the task, use `ref.value`.
await ref.value
```

The example above covers the direct usage of `TaskManagerActor`. For integrating `ConcurrencyTaskManager` seamlessly into SwiftUI applications, see the `@TaskManager` property wrapper described in the 'SwiftUI Integration' section below.

## SwiftUI Integration

The `@TaskManager` property wrapper provides a convenient way to integrate `ConcurrencyTaskManager` into your SwiftUI views. It simplifies task management and UI updates related to task execution.

### Usage Example

```swift
import SwiftUI
import ConcurrencyTaskManager // Make sure to import the module

struct MySwiftUIView: View {

    @TaskManager var taskManager
    @State private var isLoading: Bool = false
    @State private var taskResult: String = ""

    enum MyViewTask: TaskKeyType {}

    var body: some View {
        VStack {
            Button("Run Task") {
                // Clear previous result
                self.taskResult = ""

                taskManager.task(
                    isRunning: $isLoading,
                    key: .init(MyViewTask.self), // Or use .distinct() for unique tasks
                    mode: .dropCurrent 
                ) {
                    // Simulate some async work
                    try await Task.sleep(nanoseconds: 2 * 1_000_000_000) // 2 seconds
                    // Update UI on the main thread after task completion
                    return "Task Completed Successfully!"
                } onComplete: { result in
                    // Handle success or failure
                    switch result {
                    case .success(let message):
                        self.taskResult = message
                    case .failure(let error):
                        self.taskResult = "Task Failed: \(error.localizedDescription)"
                    }
                }
            }
            .disabled(isLoading) // Disable button while task is running

            if isLoading {
                ProgressView("Working...")
            } else {
                Text(taskResult)
            }
        }
        .onDisappear {
            // Optionally cancel all tasks when the view disappears
            // taskManager.cancelAllTasks()
        }
    }
}
```

### Explanation of Features

-   **`@TaskManager var taskManager`**: Declares a `TaskManager` instance that is managed by SwiftUI and tied to the view's lifecycle.
-   **`isRunning: Binding<Bool>?`**: The `task(...)` method accepts an optional `Binding<Bool>`. You can pass an `@State` variable (e.g., `$isLoading`) to this parameter. The `TaskManager` will set this binding to `true` when the task starts and `false` when it finishes (either successfully or due to an error or cancellation). This allows you to easily update your UI based on the task's state, for example, by showing a `ProgressView` or disabling a button.
-   **`cancelAllTasks()`**: You can call `taskManager.cancelAllTasks()` to cancel all tasks currently managed by that specific `TaskManager` instance. This is useful, for instance, in a view's `onDisappear` modifier to clean up any running tasks when the view is no longer visible. The `TaskManager` also automatically cancels all its tasks when the view it's part of is removed from the view hierarchy (deinited).

## Use cases

**Toggle user status**
Picture some social service - toggling the user status like favorite or not.
For the client, it needs to dispatch asynchronous requests for them.
In some case final user state would be different from what the client expected if the client dispatched multiple requests for the toggle - like the user tapped the update button continuously.

```swift
enum SomeRequestKey: TaskKeyType {}

let key = TaskKey(SomeRequestKey.self).combined(targetUserID)

await taskManager.task(key: key, mode: .dropCurrent) { ... }
```

To avoid that case, the client stops the current request before starting a new request in the queue.  
The above example binds the requests with a typed request key and target user identifier, that makes a queue for that.
