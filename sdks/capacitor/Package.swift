// swift-tools-version:5.9
// Feralin Capacitor eklentisinin iOS paketi. Capacitor CLI paket adını npm adından üretir (@feralin/capacitor → FeralinCapacitor) ve
// uygulamanın CapApp-SPM paketine `.product(name: "FeralinCapacitor", package: "FeralinCapacitor")` ekler. `Feralin` hedefi
// sdks/swift/Sources/Feralin kopyasıdır (scripts/vendor.mjs).
import PackageDescription

let package = Package(
    name: "FeralinCapacitor",
    platforms: [.iOS(.v15)],
    products: [
        .library(name: "FeralinCapacitor", targets: ["FeralinCapacitorPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ionic-team/capacitor-swift-pm.git", from: "8.0.0"),
    ],
    targets: [
        .target(
            name: "Feralin",
            path: "ios/Sources/Feralin",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "FeralinCapacitorPlugin",
            dependencies: [
                "Feralin",
                .product(name: "Capacitor", package: "capacitor-swift-pm"),
                .product(name: "Cordova", package: "capacitor-swift-pm"),
            ],
            path: "ios/Sources/FeralinCapacitorPlugin"
        ),
    ]
)
