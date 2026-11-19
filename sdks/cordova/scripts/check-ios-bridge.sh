#!/usr/bin/env bash
# Ortak iOS köprüsünü (src/ios/Plugin/FeralinBridge.swift) Feralin Swift çekirdeğiyle derler ve test/ios/BridgeTests.swift testlerini koşar.
# Cordova ve Capacitor çerçeveleri gerekmez; Linux'ta (WSL, Swift 6.x) ya da macOS'ta çalışır. UIKit, ATT, AdServices ve MarketplaceKit
# blokları Linux'ta derlenmez: bunlar için Mac ve iOS hedefi gerekir.
# Kullanım: bash sdks/cordova/scripts/check-ios-bridge.sh   (SWIFT_BIN verilirse PATH'in önüne eklenir)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sdks="$(cd "$here/.." && pwd)"
if [ -n "${SWIFT_BIN:-}" ]; then export PATH="$SWIFT_BIN:$PATH"; fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/Sources/FeralinBridgeCheck" "$work/Tests/FeralinBridgeCheckTests"
cp -r "$sdks/swift/Sources/Feralin" "$work/Sources/Feralin"
cp "$here/src/ios/Plugin/FeralinBridge.swift" "$work/Sources/FeralinBridgeCheck/"
cp "$here/test/ios/BridgeTests.swift" "$work/Tests/FeralinBridgeCheckTests/"
cat > "$work/Package.swift" <<'PKG'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "FeralinBridgeCheck",
    platforms: [.iOS(.v14), .macOS(.v11)],
    targets: [
        .target(name: "Feralin", resources: [.copy("Resources/PrivacyInfo.xcprivacy")]),
        .target(name: "FeralinBridgeCheck", dependencies: ["Feralin"]),
        .testTarget(name: "FeralinBridgeCheckTests", dependencies: ["FeralinBridgeCheck", "Feralin"]),
    ]
)
PKG
cd "$work"
swift build
swift test
