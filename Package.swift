// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PromptDock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "PromptDock", targets: ["PromptDock"])],
    targets: [.executableTarget(name: "PromptDock")]
)
