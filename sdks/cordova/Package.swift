// swift-tools-version:5.9
// Feralin Cordova eklentisinin iOS paketi (cordova-ios 8, plugin.xml içinde platform package="swift"). Ürün adı eklenti kimliğiyle
// aynı olmalıdır: cordova-ios uygulamanın CordovaPlugins paketine `.product(name: "cordova-plugin-feralin", ...)` ekler ve aşağıdaki
// cordova-ios bağımlılığını kendi yerel kopyasına çevirir. `Feralin` hedefi sdks/swift/Sources/Feralin kopyasıdır (scripts/vendor.mjs).
import PackageDescription

let package = Package(
    name: "cordova-plugin-feralin",
    platforms: [.iOS(.v14)],
    products: [
        .library(name: "cordova-plugin-feralin", targets: ["FeralinCordova"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apache/cordova-ios.git", from: "8.0.0"),
    ],
    targets: [
        .target(
            name: "Feralin",
            path: "src/ios/Feralin",
            resources: [.copy("Resources/PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "FeralinCordova",
            dependencies: ["Feralin", .product(name: "Cordova", package: "cordova-ios")],
            path: "src/ios/Plugin"
        ),
    ]
)
