<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Swift / iOS / macOS: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/swift/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Swift |
| Paket | `Feralin` |
| Sürüm | 0.4.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/swift` |
| Registry | SPM: **PUBLISHED** (sonraki adım: iOS ve macOS uygulamasında derleme ve gerçek cihaz için Mac + Xcode (BLOCKED_EXTERNAL); yeni sürümde kökte yeni düz semver etiketi) |
| Derleme | `cd sdks/swift && swift build` |
| Test | `cd sdks/swift && swift test` |

## Kurulum

```swift
// Package.swift
.package(url: "https://github.com/feralincom/sdk.git", exact: "0.4.0")
// hedef bağımlılığı
.product(name: "Feralin", package: "sdk")
```

```swift
// Package.swift
.package(path: "../sdks/swift")
// hedef bağımlılığı
.product(name: "Feralin", package: "Feralin")
```

## İlk kullanım

```swift
import Feralin

let client = try FeralinClient(configuration: .init(
    projectKey: "pk_live_...",
    collectURL: "https://collect.example.com",
    consent: Consent(analytics: kullaniciAnalitikIzniVerdi)
))

try await client.track("order_completed", properties: ["order_id": "ord_1", "amount": 249.9], userID: "user_42")
let sonuc = try await client.flush()   // ağ hatasında fırlatmaz, sonuç sonuc.error içinde
await client.close()
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | PARTIAL (Linux'ta gerçek toplayıcıya olay gönderdi ve XCTest geçti; oyun olayı yöntemleri trackLevelStart/Complete/Fail, trackEconomySource/Sink, trackRewardedAdShown/Complete, trackIapOfferShown/Initiated birim testli; iOS cihazda çalıştırılmadı) |
| batch | PARTIAL (dosya tabanlı kalıcı kuyruk ve 30 dk otomatik oturum, `storageDirectory` verilirse; Linux'ta XCTest geçti; iOS dosya koruma sınıfı dalı derlenmedi) |
| consent | PARTIAL (izin kuralları Linux'ta XCTest ve gerçek toplayıcıyla geçti; ATT durumu okuma dalı (AppTrackingTransparency) derlenmedi, pencere açılmaz) |
| identity | PARTIAL (identify, reset, group, setUserProperties, setGlobalProperties Linux'ta XCTest geçti; iOS cihazda çalıştırılmadı) |
| attribution | PARTIAL (fr_click izin kuralı, `installIdentifier` ve `bindInstall` kurulum kimliği bağlama (ADR-0007), kullanıcı girişli devam kodu mantığı Linux'ta XCTest ile geçti; SKAN modülü (`Configuration.skan`, varsayılan kapalı): kiracı şeması `skan/conversion-schema/sdk` ucundan proje anahtarıyla alınır, en yüksek değer seçimi, üç pencere, kilit, kurulum kaydı ve kalıcılık sunucu sözleşmesiyle aynı, ATT ve izinden bağımsız, childDirected'da kapalı; karar mantığı ve sunucu isteği Linux'ta sahte Apple çağrısıyla XCTest geçti (20 Kasım 2026); AdServices token alımı, SKAdNetwork ve AdAttributionKit çağrıları derlenmedi ve ÇALIŞTIRILMADI; kesin atıf yok, parmak izi yok, sunucu Apple'a sormaz; BLOCKED_EXTERNAL) |
| deeplink | PLANNED (Universal Links yok) |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı: Android ile aynı sözleşme, verified düşer, küçük birim üssü sunucuyla aynı, aynı işlem ikinci kez kuyruğa girmez; StoreKit 2: trackStoreKitPurchase, Transaction.updates dinleyicisi (captureStoreKitTransactions, varsayılan kapalı), yalnız doğrulanmış işlem, JWS makbuz belirteci (receipt.provider apple), iade/üst abonelik/aile paylaşımı gönderilmez; saf katman Linux'ta XCTest geçti (20 Kasım 2026), StoreKit köprüsü derlenmedi ve ÇALIŞTIRILMADI; REAL_VERIFIED yalnız sunucuda App Store Server API doğrulayıcısıyla (projede Apple mağaza bağlantısı ve .p8 anahtarı, BLOCKED_EXTERNAL); iade App Store Server Notifications V2 ile sunucuda; trackAdRevenue → fr_ad_revenue ve revenue_micros kuralları Linux'ta XCTest geçti) |
| error | PARTIAL (captureError ve captureUncaughtExceptions (NSException) → fr_error, çerçeve parmak izi, örnekleme ve sınır, dSYM sembolleştirmesi için en çok 5 uygulama çerçevesi (modül~UUID + göreli adres; sunucu tarafı gerçek arm64 dSYM ile sınandı), XCTest Linux'ta geçti; NSException kancası ve çerçeve yakalama yalnız Apple platformunda derlenir, ÇALIŞTIRILMADI; Swift çalışma zamanı hatası ve sinyal çökmesi yok; BLOCKED_EXTERNAL) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PARTIAL | 17 Kasım 2026: platformdan bağımsız çekirdek Linux'ta derlendi (Swift 6.4.2) ve ilk derleme üç hata buldu, düzeltildi (Linux'ta olmayan NSException kancası `#if canImport(ObjectiveC)` içine alındı; `koşul ? değer : nil` ifadesi sonlu olmayan sayıyı düşürmek yerine `.null` gönderiyordu; testlerde actor çağrıları). Apple'a özgü bloklar (`#if canImport`: Darwin/MachO, AppTrackingTransparency, AdServices, StoreKit, AdAttributionKit, ObjectiveC) derleyiciyle hâlâ doğrulanmadı; imzalar developer.apple.com belgesinden okundu. |
| build | PARTIAL | 17 Kasım 2026: Linux x86_64 (WSL, resmî Swift 6.4.2, imzası doğrulandı) üzerinde `swift build` uyarısız geçti. iOS ve macOS hedefi derlenmedi: macOS ve Xcode yok. |
| test | PARTIAL | 20 Kasım 2026: Linux'ta (WSL, Swift 6.4.2) `swift test` 149 XCTest, 0 hata (RevenueTests ve SkanTests dahil; değişiklik öncesi 121). Darwin'e bağlı testler koşmadı: TransportTests (URLProtocol sahtesi), dSYM çerçeve yakalama (`#if canImport(Darwin)`), StoreKit 2 köprüsü ve gerçek SKAdNetwork/AdAttributionKit çağrısı. |
| registry | PASS | Git etiketi 0.3.0 yayında (herkese açık depo commit 9283cc9, 19 Kasım 2026; WSL Swift ile verify-git-install --remote derlendi ve çalıştı). Önceki: 0.2.0 yayında (herkese açık depo commit 84b5c99, açıklamalı etiket (18 Kasım 2026, site sahibinin onayı)); kök Package.swift. 18 Kasım 2026, Linux (WSL, Swift 6.0.3): boş SwiftPM projesi .package(url: "https://github.com/feralincom/sdk.git", exact: "0.2.0") ile paketi uzak depodan çözdü (Package.resolved remoteSourceControl 0.2.0), derledi, import Feralin çalıştı. Xcode ile iOS derlemesi sınanmadı. |
| clean_install | PASS | 17 Kasım 2026, Linux: scripts/sdk-e2e/targets/ios-swift.mjs paketi kaynak dışına kopyalar, boş tüketici SwiftPM yerel yol bağımlılığıyla `swift run -c release` derler. Xcode ile iOS uygulamasına kurulum denenmedi. |
| event_receipt | PASS | 17 Kasım 2026, Linux süreci: `node scripts/sdk-e2e/run.mjs ios-swift` gerçek services/collect ile geçti (202 ve outbox, fr_click izin kuralı, izinsiz üretmeme, yanlış anahtar 401, idempotent tekrar; outbox 7 satır, ClickHouse'ta 3 olay tam bir kez). Olay platformu `other` gider (Linux); gerçek iOS cihaz ve simülatör koşusu yok, SDK-R07 BLOCKED_EXTERNAL. |
| documentation | PASS | docs/sdk/ios-swift.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
