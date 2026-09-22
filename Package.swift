// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Pencil",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure, AppKit-free logic (stroke model, laser fade, path smoothing, modes).
        .target(name: "PencilCore"),
        // The menu-bar app itself.
        .executableTarget(name: "Pencil", dependencies: ["PencilCore"]),
        .testTarget(name: "PencilCoreTests", dependencies: ["PencilCore"]),
    ]
)
