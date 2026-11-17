// swift-tools-version:5.9
// Herkese açık SDK deposunun (github.com/feralincom/sdk) kök paket bildirimi. Swift Package Manager bildirimi yalnız depo
// kökünde arar; kaynak sdks/swift altındadır. Dışa aktarım betiği bu dosyayı depo köküne kopyalar
// (scripts/sdk-publish/export-public-repo.mjs). Platformlar ve kaynak kuralı sdks/swift/Package.swift ile aynı tutulur;
// eşitlik scripts/sdk-publish/test/export-public-repo.test.mjs içinde denetlenir.
//
// Sürüm etiketi kökte düz semver'dir (ör. 0.2.0): SPM başka biçimdeki etiketleri (sdks/go/v0.1.0 gibi) yok sayar.
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
            path: "sdks/swift/Sources/Feralin",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .testTarget(name: "FeralinTests", dependencies: ["Feralin"], path: "sdks/swift/Tests/FeralinTests"),
    ]
)
