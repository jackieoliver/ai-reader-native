// swift-tools-version: 6.0

import PackageDescription

let package = Package(
  name: "AIReader",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "AIReader", targets: ["AIReaderApp"])
  ],
  targets: [
    .target(name: "AIReaderCore"),
    .executableTarget(
      name: "AIReaderApp",
      dependencies: ["AIReaderCore"]
    ),
    .testTarget(
      name: "AIReaderCoreTests",
      dependencies: ["AIReaderCore"]
    )
  ]
)
