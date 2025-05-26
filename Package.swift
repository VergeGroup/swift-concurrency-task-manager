// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "swift-concurrency-task-manager",
  platforms: [
    .macOS(.v11),
    .iOS(.v14),
    .tvOS(.v16),
    .watchOS(.v10)
  ],
  products: [
    // Products define the executables and libraries a package produces, making them visible to other packages.
    .library(
      name: "ConcurrencyTaskManager",
      targets: ["ConcurrencyTaskManager"]
    )
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0")
  ],
  targets: [
    // Targets are the basic building blocks of a package, defining a module or a test suite.
    // Targets can depend on other targets in this package and products from dependencies.
    .target(
      name: "ConcurrencyTaskManager",
      dependencies: [
        .product(name: "DequeModule", package: "swift-collections")
      ]
    ),
    .testTarget(
      name: "ConcurrencyTaskManagerTests",
      dependencies: ["ConcurrencyTaskManager"]
    ),
  ],
  swiftLanguageModes: [.v5, .v6]
)
