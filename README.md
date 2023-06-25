# TaskManager - Swift Concurrency

## Overview

swift-concurrency supports structured concurrency but it also supports unstructured concurrency using Task API.
Task API runs immediately its work item. Although using closure can make deferred tasks.

TaskManager accepts work items to run in a serial queue isolated by the key.  
Passing key and mode (drop current items / wait in current items)

## Usage

```swift

enum MyTask: TaskKeyType {}

let manager = TaskManager()

// this `await` is just for appending task item since TaskManager is Actor.
let ref = await manager.task(key: .init(MyTask.self), mode: .dropCurrent) {
  // work
}

// to wait the completion of the task, use `ref.value`.
await ref.value
```

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
