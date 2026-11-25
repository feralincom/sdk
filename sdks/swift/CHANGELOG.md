# Değişiklik günlüğü

Herkese açık depodan (github.com/feralincom/sdk) Git etiketiyle kurulur: `0.3.0` yayımlı (19 Kasım 2026). Swift kodu Linux'ta Swift 6.4.2 ile derlenir ve test edilir; Xcode, iOS cihazı ve StoreKit/SKAN'ın cihazdaki davranışı Mac gerektirir (`docs/MAC_GOREVLERI.md`). Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## 0.4.0 (yayın adayı, 25 Kasım 2026; Git etiketi `0.4.0` gönderilince yayımlanır)

- Satın alma geliri (`Revenue.swift`): `trackRevenue(_:)` ve `trackRevenue(amount:currency:productID:transactionID:...)` → `feralin_purchase` (Android, Flutter ve Web ile aynı sözleşme; `verified` düşer, tutar küçük birimde tam sayı, üs kuralı sunucuyla aynı). Aynı işlem bu kurulumda ikinci kez kuyruğa girmez (`storageDirectory` verilirse `feralin-purchases-v1.json`). Yeni türler `RevenueInput`, `PurchaseType`, `PurchaseReceipt`, `MinorUnits`, `StoreKitCaptureOutcome`.
- StoreKit 2 (`StoreKitCapture.swift`, `#if canImport(StoreKit)`): `trackStoreKitPurchase`, `trackStoreKitTransaction`, `startStoreKitTransactionCapture` ve `Configuration.captureStoreKitTransactions` (varsayılan kapalı). Yalnız doğrulanmış işlem gider, JWS makbuz belirtecidir; iade, üst aboneliğe geçiş ve aile paylaşımı gelir sayılmaz. Xcode'da derlenmedi.
- SKAN dönüşüm değeri modülü (`Skan.swift`): `Configuration.skan` (varsayılan kapalı), `refreshSkanSchema()`, `lastSkanUpdate`. Kiracı şeması `skan/conversion-schema/sdk` ucundan alınır; en yüksek değer seçimi, üç pencere, kilit ve kurulum kaydı sunucu sözleşmesiyle aynı. ATT ve izinden bağımsız, `childDirected` açıkken kapalı.
- Gizlilik bildirimi: `NSPrivacyCollectedDataTypePurchaseHistory` eklendi.
- Linux'ta (20 Kasım 2026, Swift 6.4.2) `swift build` uyarısız, `swift test` 149 XCTest geçti (28 yeni test: `RevenueTests`, `SkanTests`).

## 0.3.0 (19 Kasım 2026)

- SPM ile Git'ten kurulum: herkese açık depo kökündeki `Package.swift` bu paketi gösterir; `.package(url: "https://github.com/feralincom/sdk.git", exact: "0.2.0")`, ürün `Feralin`, paket kimliği `sdk`. Sürüm etiketi kökte düz semver (`0.2.0`); etiket henüz gönderilmedi (17 Kasım 2026).
- Kurulum eşleştirme kodu: `Configuration.installCode` (yeni, varsayılanı `nil`, kaynak uyumlu). Kod kuyruğa giren ilk olaya `fr_install_code` olarak eklenir; biçimi bozuk kod yok sayılır, izinsiz ya da doğrulamada düşen olay kodu harcamaz. Android, Flutter ve Web SDK'larıyla aynı sözleşme. Linux'ta 2 XCTest ile sınandı (17 Kasım 2026).
- İlk gerçek derleme ve koşu (17 Kasım 2026, Linux x86_64, Swift 6.4.2): `swift build` uyarısız, `swift test` 87 XCTest, gerçek toplayıcıyla uçtan uca test geçti. Bulunan ve düzeltilen hatalar: sonlu olmayan sayı (`NaN`, sonsuz) kullanıcı ve global özelliğinde düşmek yerine `null` olarak gidiyordu (`koşul ? değer : nil`, `FeralinValue` nil literal'i yüzünden `.null` oluyordu); `captureUncaughtExceptions` Objective-C çalışma zamanı olmayan platformda derlenmiyordu (artık `#if canImport(ObjectiveC)`, Linux'ta etkisiz); testlerde actor çağrıları `XCTAssert*` autoclosure'ı içinde bekleniyordu; dSYM çerçeve sözleşmesi testindeki beklenen sütun yanlış hesaplanmıştı (0x2a3b4c5 = 44283077). Apple'a özgü bloklar ve iOS hedefi hâlâ derlenmedi.
- iOS dSYM sembolleştirme çerçeveleri (`AppleFrames.swift`): `captureError(..., returnAddresses:)` ve yakalanmamış `NSException` artık uygulama görüntülerine düşen en çok 5 çerçeveyi `frames` olarak gönderir (`<modül>~<uuid>`, göreli adres satır/sütuna bölünmüş). Yeni parametre varsayılan değerlidir, kaynak uyumludur. Sunucu `POST /v1/projects/{id}/dsyms` ile yüklenen dSYM'den çözer. Çerçeve yakalama yalnız Apple platformunda derlenir ve koşmadı (macOS yok); sözleşme testi Linux'ta geçti (16 Kasım 2026).
- UTP §8.2 kimlik yöntemleri (`Profile.swift`): `group` (`fr_group`), `setUserProperties` (`fr_user_properties`), `setGlobalProperties`, `clearGlobalProperties`; `reset()` globalleri de siler. Kurallar toplayıcıyla aynı. `ProfileTests.swift` 17 Kasım 2026'da Linux'ta geçti (13 Kasım 2026).

## 0.2.0 (yayınlanmadı)

- Hata, oyun ve reklam geliri olayları (`Signals.swift`): `captureError` ve `captureUncaughtExceptions` (NSException) → `fr_error`, çerçeve parmak izi, örnekleme ve hız sınırı; `trackLevelStart/Complete/Fail`, `trackEconomySource/Sink`, `trackRewardedAdShown/Complete`, `trackIapOfferShown/Initiated`; `trackAdRevenue` → `fr_ad_revenue`. `SDKIdentity` sürümü `0.2.0` (12 Kasım 2026).

## 0.1.0 (yayınlanmadı)

- İlk istemci: `URLSession` ve `actor`, izin kapılı olay, sınırlı kuyruk, üstel geri çekilme, ATT durumunu reklam iznine yansıtma (pencere açılmaz), AdServices token'ı, SKAdNetwork ve AdAttributionKit çağrıları, gizlilik bildirimi (`PrivacyInfo.xcprivacy`) (6 Kasım 2026).
- Kurulum kimliği bağlama: `installIdentifier` ve `bindInstall` (11 Kasım 2026).
- İsteğe bağlı kalıcı kuyruk ve 30 dakikalık otomatik oturum (`storageDirectory`): atomik dosya yazımı, olay yalnız 202 ya da kalıcı ret sonrası silinir, aynı `event_id` ile yeniden deneme. Olay gövdeleri diskte şifreli değildir (12 Kasım 2026).
