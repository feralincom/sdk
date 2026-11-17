// swift-tools-version:5.9
import PackageDescription

// Temiz tüketici: scripts/sdk-e2e/targets/objc.mjs boş çalışma alanına kopyalar ve FERALIN_OBJC_PATH ile bağlar.
let sdkPath = Context.environment["FERALIN_OBJC_PATH"] ?? "../.."
let corePath = Context.environment["FERALIN_SDK_PATH"] ?? "../../../swift"

let package = Package(
    name: "FeralinObjCE2E",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(name: "FeralinObjC", path: sdkPath),
        .package(name: "Feralin", path: corePath),
    ],
    targets: [
        .executableTarget(name: "FeralinObjCE2E", dependencies: [
            .product(name: "FeralinObjC", package: "FeralinObjC"),
            .product(name: "Feralin", package: "Feralin"),
        ]),
    ]
)
