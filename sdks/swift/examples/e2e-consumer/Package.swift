// swift-tools-version:5.9
import PackageDescription

// Temiz tüketici: scripts/sdk-e2e/targets/ios-swift.mjs bu dizini boş çalışma alanına kopyalar ve FERALIN_SDK_PATH ile bağlar.
let sdkPath = Context.environment["FERALIN_SDK_PATH"] ?? "../.."

let package = Package(
    name: "FeralinE2E",
    platforms: [.macOS(.v12)],
    dependencies: [.package(name: "Feralin", path: sdkPath)],
    targets: [
        .executableTarget(name: "FeralinE2E", dependencies: [.product(name: "Feralin", package: "Feralin")]),
    ]
)
