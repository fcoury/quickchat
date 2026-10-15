// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuickChat",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuickChat", targets: ["QuickChat"])],
    targets: [
        .target(name: "QuickChatCore"),
        .executableTarget(name: "QuickChat", dependencies: ["QuickChatCore"]),
        .testTarget(name: "QuickChatCoreTests", dependencies: ["QuickChatCore", "QuickChat"])
    ],
    swiftLanguageModes: [.v5]
)
