// swift-tools-version: 5.8
import PackageDescription
let package = Package(name: "WanderRead", platforms: [.macOS(.v13)], products: [.executable(name: "WanderRead", targets: ["WanderRead"])], targets: [.executableTarget(name: "WanderRead", path: "Sources/WanderRead")])
