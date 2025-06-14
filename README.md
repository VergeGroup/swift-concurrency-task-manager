# 🎯 TaskManager for Swift Concurrency

> Elegant task orchestration for Swift apps - Control concurrent operations with precision

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%2014%2B%20%7C%20macOS%2011%2B%20%7C%20tvOS%2016%2B%20%7C%20watchOS%2010%2B-lightgrey.svg)](https://swift.org)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)

## Introduction

TaskManager is a powerful Swift library that brings order to chaos in asynchronous programming. While Swift's structured concurrency is excellent, unstructured tasks created with `Task { }` run immediately and can lead to race conditions, redundant operations, and unpredictable behavior.

TaskManager solves this by providing:
- **Task isolation by key** - Group related operations together
- **Execution control** - Choose whether to cancel existing tasks or queue new ones
- **SwiftUI integration** - First-class support for UI-driven async operations
- **Actor-based safety** - Thread-safe by design using Swift actors

## 🚀 Installation

### Swift Package Manager

Add TaskManager to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/muukii/swift-concurrency-task-manager.git", from: "1.0.0")
]
```

Or add it through Xcode:
1. File → Add Package Dependencies
2. Enter the repository URL
3. Click "Add Package"

## 📋 Requirements

- Swift 6.0+
- iOS 14.0+ / macOS 11.0+ / tvOS 16.0+ / watchOS 10.0+
- Xcode 15.0+

## 🎓 Core Concepts

### TaskKey

A `TaskKey` is a unique identifier that groups related operations. Tasks with the same key are managed together, allowing you to control their execution behavior.

```swift
// Type-based keys for strong typing
enum UserOperations: TaskKeyType {}
let key = TaskKey(UserOperations.self)

// String-based keys for simplicity
let key: TaskKey = "user-fetch"

// Dynamic keys with combined values
let key = TaskKey(UserOperations.self).combined(userID)

// Unique keys for one-off operations
let key = TaskKey.distinct()

// Code location-based keys
let key = TaskKey.code() // Uses file:line:column
```

### Execution Modes

TaskManager offers two execution modes:

- **`.dropCurrent`** - Cancels any running task with the same key before starting the new one
- **`.waitInCurrent`** - Queues the new task to run after existing tasks complete

### Task Isolation

Tasks are isolated by their keys, meaning operations with different keys run concurrently, while operations with the same key are managed according to their mode.

## 💡 Basic Usage

### Simple Task Management

```swift
let manager = TaskManagerActor()

// Drop any existing user fetch and start a new one
let task = await manager.task(
    key: TaskKey("user-fetch"),
    mode: .dropCurrent
) {
    let user = try await api.fetchUser()
    return user
}

// Wait for the result
let user = try await task.value
```

### Real-World Example: Search-as-you-type

```swift
class SearchViewModel {
    let taskManager = TaskManagerActor()
    
    func search(query: String) async {
        // Cancel previous search when user types
        await taskManager.task(
            key: TaskKey("search"),
            mode: .dropCurrent
        ) {
            // Debounce
            try await Task.sleep(for: .milliseconds(300))
            
            let results = try await api.search(query)
            await MainActor.run {
                self.searchResults = results
            }
        }
    }
}
```

## 🎨 SwiftUI Integration

TaskManager provides a property wrapper for seamless SwiftUI integration:

```swift
struct UserProfileView: View {
    @TaskManager var taskManager
    @State private var isLoading = false
    @State private var user: User?
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView()
            } else if let user {
                Text(user.name)
            }
            
            Button("Refresh") {
                taskManager.task(
                    isRunning: $isLoading,
                    key: TaskKey("fetch-user"),
                    mode: .dropCurrent
                ) {
                    user = try await api.fetchCurrentUser()
                }
            }
        }
    }
}
```

## 🔥 Advanced Usage

### Dynamic Task Keys

Create sophisticated task isolation strategies:

```swift
// Isolate tasks per user
func updateUserStatus(userID: String, isFavorite: Bool) async {
    let key = TaskKey(UserOperations.self).combined(userID)
    
    await taskManager.task(key: key, mode: .dropCurrent) {
        try await api.updateUserStatus(userID, favorite: isFavorite)
    }
}

// Isolate tasks per resource and operation
func downloadImage(url: URL, size: ImageSize) async {
    let key = TaskKey("image-download")
        .combined(url.absoluteString)
        .combined(size.rawValue)
    
    await taskManager.task(key: key, mode: .waitInCurrent) {
        try await imageLoader.download(url, size: size)
    }
}
```

### Batch Operations

Execute multiple operations efficiently:

```swift
await taskManager.batch { manager in
    // These run concurrently (different keys)
    manager.task(key: TaskKey("fetch-user"), mode: .dropCurrent) {
        userData = try await api.fetchUser()
    }
    
    manager.task(key: TaskKey("fetch-posts"), mode: .dropCurrent) {
        posts = try await api.fetchPosts()
    }
    
    manager.task(key: TaskKey("fetch-settings"), mode: .dropCurrent) {
        settings = try await api.fetchSettings()
    }
}
```

### Task State Management

Control task execution flow:

```swift
let manager = TaskManagerActor()

// Pause all task execution
await manager.setIsRunning(false)

// Tasks will queue but not execute
await manager.task(key: TaskKey("operation"), mode: .waitInCurrent) {
    // This won't run until isRunning is true
}

// Resume execution
await manager.setIsRunning(true)

// Check if a specific task is running
let isRunning = await manager.isRunning(for: TaskKey("operation"))
```

### Error Handling

TaskManager preserves Swift's native error handling:

```swift
do {
    let result = try await taskManager.task(
        key: TaskKey("risky-operation"),
        mode: .dropCurrent
    ) {
        try await riskyOperation()
    }.value
} catch is CancellationError {
    print("Task was cancelled")
} catch {
    print("Task failed: \(error)")
}
```

## 🏗️ Architecture Patterns

### Repository Pattern

```swift
class UserRepository {
    private let taskManager = TaskManagerActor()
    
    func fetchUser(id: String, forceRefresh: Bool = false) async throws -> User {
        let key = TaskKey(UserOperations.self).combined(id)
        let mode: TaskManagerActor.Mode = forceRefresh ? .dropCurrent : .waitInCurrent
        
        return try await taskManager.task(key: key, mode: mode) {
            // Check cache first
            if !forceRefresh, let cached = await cache.get(id) {
                return cached
            }
            
            // Fetch from network
            let user = try await api.fetchUser(id)
            await cache.set(user, for: id)
            return user
        }.value
    }
}
```

### ViewModel Pattern

```swift
@Observable
class ProductListViewModel {
    private let taskManager = TaskManagerActor()
    var products: [Product] = []
    var isLoading = false
    
    func loadProducts(category: String? = nil) {
        Task {
            await taskManager.task(
                key: TaskKey("load-products").combined(category ?? "all"),
                mode: .dropCurrent
            ) {
                await MainActor.run { self.isLoading = true }
                defer { Task { @MainActor in self.isLoading = false } }
                
                let products = try await api.fetchProducts(category: category)
                await MainActor.run {
                    self.products = products
                }
            }
        }
    }
}
```

## 📚 API Reference

### TaskManagerActor

The main actor that manages task execution.

#### Methods

- `task(label:key:mode:priority:operation:)` - Submit a task for execution
- `taskDetached(label:key:mode:priority:operation:)` - Submit a detached task
- `batch(_:)` - Execute multiple operations in a batch
- `setIsRunning(_:)` - Control task execution state
- `isRunning(for:)` - Check if a task is running for a given key
- `cancelAll()` - Cancel all managed tasks

### TaskKey

Identifies and groups related tasks.

#### Initialization

- `init(_:TaskKeyType)` - Create from a type
- `init(_:String)` - Create from a string
- `init(_:Int)` - Create from an integer
- `init(_:Hashable & Sendable)` - Create from any hashable value

#### Methods

- `combined(_:)` - Combine with another key
- `static func distinct()` - Create a unique key
- `static func code()` - Create a key from source location

### SwiftUI Components

#### @TaskManager Property Wrapper

Provides TaskManager functionality in SwiftUI views with automatic lifecycle management.

#### TaskManagerActorWrapper

SwiftUI-friendly wrapper with `isRunning` binding support.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

TaskManager is available under the Apache 2.0 license. See the [LICENSE](LICENSE) file for more info.

## 🙏 Acknowledgments

Built with ❤️ using Swift's modern concurrency features and inspired by the need for better async task control in real-world applications.