// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FeralinObjC",
    platforms: [.iOS(.v14), .macOS(.v11), .tvOS(.v14), .watchOS(.v7)],
    products: [
        .library(name: "FeralinObjC", targets: ["FeralinObjC"]),
    ],
    dependencies: [
        .package(name: "Feralin", path: "../swift"),
    ],
    targets: [
        .target(name: "FeralinObjC", dependencies: [.product(name: "Feralin", package: "Feralin")]),
        .testTarget(name: "FeralinObjCTests", dependencies: ["FeralinObjC", .product(name: "Feralin", package: "Feralin")]),
        // Köprünün Objective-C başlığından gerçekten göründüğünü sınar.
        .testTarget(name: "FeralinObjCHeaderTests", dependencies: ["FeralinObjC"]),
    ]
)
