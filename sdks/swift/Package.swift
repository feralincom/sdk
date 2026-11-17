// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Feralin",
    platforms: [.iOS(.v14), .macOS(.v11), .tvOS(.v14), .watchOS(.v7)],
    products: [
        .library(name: "Feralin", targets: ["Feralin"]),
    ],
    targets: [
        .target(
            name: "Feralin",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "FeralinTests", dependencies: ["Feralin"]),
    ]
)
