// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Blanko",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Blanko", path: "Sources/Blanko")
    ]
)
