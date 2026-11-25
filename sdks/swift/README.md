# Feralin Swift SDK

iOS, iPadOS, macOS, tvOS ve watchOS için UTP v1 istemcisi. `URLSession` ve `actor` kullanır, dış bağımlılığı yoktur. Olaylar `POST /v1/batch` üzerinden gider. Kapsam: izin kapılı olay, sınırlı kuyruk (isteğe bağlı kalıcı), 30 dk otomatik oturum, üstel geri çekilme, Apple attribution çağrıları, satın alma geliri (`trackRevenue`, StoreKit 2) ve SKAN dönüşüm değeri modülü.

## Durum

| Konu | Durum |
|---|---|
| Kod ve testler | **Platformdan bağımsız çekirdek Linux'ta derlendi ve sınandı (17 Kasım 2026, Swift 6.4.2).** Apple'a özgü bloklar (`#if canImport`: Darwin/MachO, AppTrackingTransparency, AdServices, StoreKit, AdAttributionKit, ObjectiveC) ve iOS hedefi hiç derlenmedi: macOS ve Xcode yok. `lifecycle: INTEGRATION_TESTED` |
| `swift build`, `swift test` | Linux x86_64 (20 Kasım 2026, Swift 6.4.2): derleme uyarısız, 149 XCTest geçti (gelir ve SKAN dahil). Darwin'e bağlı testler (TransportTests, dSYM çerçeve yakalama), StoreKit 2 köprüsü (`StoreKitCapture.swift`) ve iOS/macOS derlemesi `NOT_RUN` |
| Gerçek `services/collect` | `node scripts/sdk-e2e/run.mjs ios-swift` Linux'ta geçti: temiz tüketici, outbox 7 satır, ClickHouse'ta 3 olay tam bir kez. Olay platformu Linux'ta `other` gider; iOS cihaz ve simülatör `NOT_RUN` |
| Gerçek cihaz ve App Store | `BLOCKED_EXTERNAL`: Apple Developer hesabı, yayınlı uygulama, Apple Ads kampanyası |
| SPM yayını (Git tag) | Yayında: etiket `0.3.0` (herkese açık depo <https://github.com/feralincom/sdk>, 19 Kasım 2026); temiz SPM kurulumu Linux'ta derlendi ve çalıştı. `0.4.0` (gelir, StoreKit 2, SKAN) yayın adayı: etiket gönderilince kurulabilir |

Apple'a özgü API imzaları ve sürümleri developer.apple.com belgesinden doğrulandı; derleyiciyle doğrulanmadı. Xcode ile ilk derlemede denenecek riskler aşağıda. İlk Linux derlemesi iki gerçek hata buldu ve düzeltildi: sonlu olmayan sayı (`NaN`) özellik olarak düşmek yerine `null` gidiyordu, testlerde actor çağrıları derlenmiyordu.

## Gereksinimler

Swift 5.9 araç zinciri (Xcode 15+). iOS 14, macOS 11, tvOS 14, watchOS 7.

## Kurulum

Paket herkese açık depodadır: <https://github.com/feralincom/sdk>. Swift Package Manager bildirimi yalnız depo kökünde aradığı için depo kökünde `sdks/swift` kaynağını gösteren bir `Package.swift` vardır. Sürüm etiketi kökte düz semver'dir (`0.2.0`); paket kimliği adresin son parçasıdır (`sdk`).

Xcode: **File → Add Package Dependencies…** → `https://github.com/feralincom/sdk.git` → **Exact Version** `0.4.0` → ürün `Feralin`. Ya da `Package.swift`:

```swift
// Package.swift
.package(url: "https://github.com/feralincom/sdk.git", exact: "0.4.0")
// hedef bağımlılığı
.product(name: "Feralin", package: "sdk")
```

Etiket depoya gönderilmeden çözümleme "no versions" hatası verir; yayımlanmış etiketler <https://github.com/feralincom/sdk/tags> sayfasındadır. SPM depoyu bütünüyle klonlar (öteki SDK'lar dahil, birkaç MB); derlemeye yalnız `sdks/swift/Sources/Feralin` girer.

Etiket yokken ya da yerel kopyayla:

```swift
// Package.swift
.package(path: "../sdks/swift")
// hedef bağımlılığı
.product(name: "Feralin", package: "Feralin")
```

## En kısa örnek

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

`sk_` ile başlayan gizli anahtar reddedilir. Doğrulama hatası `FeralinError.invalidEvent` fırlatır; teslim hataları uygulamayı düşürmez.

## Kurulumu doğrulama (eşleştirme kodu)

Panelin "Kurulumu doğrula" ekranı tek kullanımlık bir kod üretir. Kod yapılandırmaya verilir; SDK onu süreçte kuyruğa giren ilk olaya `fr_install_code` özelliği olarak ekler ve sunucu bu kurulumu projeye bağlar.

```swift
let client = try FeralinClient(configuration: .init(
    projectKey: "pk_live_...",
    collectURL: "https://collect.example.com",
    consent: Consent(analytics: true),
    installCode: "ABCDE-FGHJK"
))
```

Kod kişisel veri değildir ve 30 dakika geçerlidir; doğrulamadan sonra yapılandırmadan kaldırılabilir. Biçimi bozuk kod yok sayılır. `analytics` izni yokken olay üretilmediği için kod harcanmaz; doğrulamada düşen olay da kodu harcamaz. Linux'ta XCTest ile sınandı (17 Kasım 2026).

## İzin

SDK kararı saklamaz; kararın sahibi uygulamadır, her açılışta `consent` ile verilir, değişince `setConsent` çağrılır.

- `analytics` yoksa olay üretilmez, `track` `nil` döner. Geri çekilince kuyruk ve saklı kurulum kimliği silinir.
- `advertising` yoksa `fr_click` çıkarılır; AdServices token'ı alınmaz, devam kodu kullanılmaz, dönüşüm değeri bildirilmez.
- SDK ATT penceresi göstermez. `requestTrackingAuthorization` ve `NSUserTrackingUsageDescription` uygulamanındır.
- ATT istemcide zorlanır: `advertising: true` verilse bile `FeralinClient` ATT durumunu `track`, `submitAdServicesToken`, `redeemContinuityCode`, `updateConversionValue` ve `status` çağrılarının her birinde okur.

| ATT durumu | Reklam izni |
|---|---|
| `authorized` | Uygulamanın kararı geçerli |
| `denied`, `restricted`, Apple'ın ileride ekleyeceği bilinmeyen durum | Kapalı |
| `notDetermined` | Kapalı. Uygulama ATT penceresini gösterene kadar `fr_click` gitmez, token alınmaz, dönüşüm değeri bildirilmez. Pencere sonrası `authorized` olursa yeniden `setConsent` gerekmez |
| `unavailable` (ATT'nin olmadığı platform, ör. watchOS) | Uygulamanın kararı geçerli |

ATT analitik iznini değiştirmez: `analytics` açıksa olaylar `fr_click` olmadan gider ve `consent.advertising` değeri `false` yazılır. ATT durumunu arayüzde göstermek için `FeralinApple.trackingAuthorizationStatus()`, hesap için `Consent.constrained(by:)` açıktır; SDK'nın doğru çalışması için çağrılmaları gerekmez.

Kurulum kimliği rastgele bir ULID'dir, `UserDefaults` içinde yalnız analitik izni varken tutulur. IDFA, IDFV ve cihaz parmak izi okunmaz, gönderilmez. Normal web → App Store → kurulum yolu için kesin tekil atıf iddia edilmez.

### Gizlilik bildirimi

`Sources/Feralin/Resources/PrivacyInfo.xcprivacy` koda göre şunları beyan eder; App Store Connect etiketi uygulama sahibinindir:

| Tür | Karşılığı | Kimliğe bağlı | Amaç |
|---|---|---|---|
| `ProductInteraction` | Olay adı ve özellikleri | Evet: olaylar `anonymous_id` ve varsa `user_id` taşır | Analytics |
| `UserID` | `user_id` ve kalıcı rastgele kurulum kimliği | Evet | Analytics |
| `PurchaseHistory` | `trackRevenue` ve StoreKit 2 satın alma olayları (`feralin_purchase`) | Evet | Analytics |
| `AdvertisingData` | `fr_click`, AdServices token | Evet | Analytics |

Kurulum kimliği donanıma değil, uygulama kurulumuna atanmış rastgele değerdir; IDFA, IDFV okunmadığından `DeviceID` beyan edilmez.

`NSPrivacyTracking` değeri `false`: SDK IDFA okumaz, veri aracısına ve üçüncü taraf alan adına veri göndermez, tek hedefi müşterinin yapılandırdığı toplayıcıdır. `true` değeri izinsiz durumda engellenecek sabit alan adı listesi ister; toplayıcı adresi müşteriye özeldir ve analitik de aynı adrese gider.

Doğrulanamayanlar: Bu sınıflandırma Apple tanımlarından yapılan yorumdur, App Review ile sınanmadı. `fr_click` başka şirketlerin sitelerinden gelen tıklamalarla eşleştiriliyorsa bu kullanım Apple'ın "tracking" tanımına girebilir; bu kararı yalnız kampanya kurgusunu bilen uygulama sahibi verebilir ve gerekiyorsa kendi manifestinde `NSPrivacyTracking` ile kendi alan adını beyan eder. Manifestin Xcode gizlilik raporundaki birleşik çıktısı denenmedi.

## Attribution

Kesin attribution garanti edilmez. Aşağıdaki hiçbir çağrı tek başına atıf kanıtı değildir ve `unknown` geçerli sonuçtur.

```swift
let client = try FeralinClient(configuration: .init(
    projectKey: "pk_live_...",
    collectURL: "https://collect.example.com",
    consent: Consent(analytics: true, advertising: true),
    attribution: AttributionConfiguration(apiURL: "https://api.example.com", projectID: "proj_...")
))
```

| Yöntem | Ne yapar | Sınır |
|---|---|---|
| `submitAdServicesToken()` | `AAAttribution.attributionToken()` alır, `POST {api}/v1/projects/{id}/attribution/apple-adservices/tokens` | iOS 14.3, macOS 11.1; tvOS ve watchOS'ta `notSupported`. Sunucu Apple'a sormaz: yanıt `BLOCKED_EXTERNAL`, karar üretilmez |
| `installIdentifier()` | Kurulum kimliğini (ADR-0007) döndürür | Reklam ölçümü izni (ATT dâhil) yoksa `nil`. Kimliği kendi sunucunuza iletin; sunucu gizli API anahtarıyla `POST /v1/projects/{id}/attribution/account-links` (`surface=app`, `subject_id=<kimlik>`) çağırır. SDK hesap kimliği yazmaz |
| `bindInstall()` | AdServices token'ını bu kimlikle gönderir ve `InstallBinding(installID, adServices)` döndürür | Token alınamasa (`notSupported`, `tokenUnavailable`) da `installID` hesap bağı için geçerlidir. Derlenmedi: macOS yok |
| `redeemContinuityCode(_:)` | `POST {api}/v1/projects/{id}/attribution/continuity-tokens/redeem` | Yalnız kullanıcı kodu girdiğinde çağırın; SDK panoyu okumaz. Sonuç eşleşen ilk açılıştır, indirme sayısı değildir. Sözleşmede macOS, tvOS, watchOS değeri yok: `notSupported` |
| `updateConversionValue(fine:coarse:lock:frameworks:)` | SKAdNetwork (iOS 16.1) ve AdAttributionKit (iOS 17.4) | Elle çağrı; reklam izni ister. Kiracı şemasıyla otomatik güncelleme için aşağıdaki SKAN modülü. `called` yalnız çağrının hatasız döndüğünü söyler; bekleyen postback yoksa sistem çağrıyı yok sayar |

Attribution uçlarında proje anahtarı `Authorization: Bearer` ile gider, `X-Feralin-Project-Key` yalnız toplayıcıdadır. Token saklanmaz ve loglanmaz.

### Bağlantılar: açılış, ertelenmiş derin bağlantı, pano eşlemesi

```swift
// Universal Link ile açılış: olayı gönderir, uygulamanın açacağı yolu döner.
let open = try await client.handleUniversalLink(url)        // open.destination == "/urun/42?renk=mavi"

// İlk açılış ve ertelenmiş derin bağlantı (kurulumdan sonraki ilk açılışta bir kez).
let click = await client.clipboardClickID(linkHosts: ["feralin.com", "go.markaniz.com"])   // izinli pano eşlemesi; istemezseniz çağırmayın
try await client.trackFirstOpen(clickID: click, source: click == nil ? nil : "clipboard")
if case .matched(let link) = await client.fetchDeferredDeepLink(), let path = link.deepLinkPath {
    router.open(path)
}
```

- `handleUniversalLink(_:)` `deep_link_opened` olayını `attribution_source = universal_link` ile gönderir. Reklam ölçümü izni yoksa tıklama
  kimliği olaya eklenmez; yol yine döner.
- `fetchDeferredDeepLink()` sunucuya `POST /v1/projects/{id}/attribution/deferred-link` ile sorar (`attribution` yapılandırması ve reklam
  ölçümü izni gerekir). Karar birkaç saniyede yazıldığı için `pending` yanıtında kısa aralıkla yeniden sorar (varsayılan 4 deneme).
  Eşleşme yöntemi yanıttadır (`evidenceClass`): pano, olasılıksal eşleme ya da başka kanıt; kesinlik iddia edilmez.
- `clipboardClickID(linkHosts:)` panoyu yalnız reklam ölçümü izni varken okur ve yalnız verdiğiniz hostlara ait, `fr_click` taşıyan `https`
  adresini kabul eder; başka pano içeriği saklanmaz ve gönderilmez. iOS okuma sırasında kullanıcıya yapıştırma izni sorabilir. Panoya
  yazan taraf link yönlendiricisinin ara sayfasıdır: linkte "iOS pano eşlemesi" açıksa kullanıcı düğmeye basınca adres kopyalanır.
- `UIPasteboard` çağrısı yalnız iOS'ta derlenir (`#if canImport(UIKit)`); Linux'ta derlenen ve sınanan kısım adres çözümlemesi, izin
  kapısı ve sunucu çağrısıdır. Gerçek cihazda pano izni penceresi ve Universal Link teslimi Mac ve cihaz ister: bu repoda sınanmadı.

## Kalıcı kuyruk ve oturum

`storageDirectory` verilirse kuyruk diskte de tutulur; uygulama kapanınca ya da çökünce gönderilmemiş olaylar bir sonraki açılışta geri yüklenir. Verilmezse kuyruk yalnız bellektedir (eski davranış). Dizin tek bir istemciye aittir.

```swift
let client = try FeralinClient(configuration: .init(
    projectKey: "pk_live_...",
    collectURL: "https://collect.example.com",
    consent: Consent(analytics: kullaniciAnalitikIzniVerdi),
    storageDirectory: FeralinClient.defaultStorageDirectory()   // Application Support/Feralin
))
```

- Dosyalar `feralin-queue-v1.json` ve `feralin-session-v1.json`; her yazım atomiktir, iOS/tvOS/watchOS'ta `completeFileProtectionUntilFirstUserAuthentication` ile korunur ve yedekten hariç tutulur. Olay gövdeleri şifreli değildir.
- Kuyruk her `track` ve her teslim sonucunda yazılır. Olaylar yalnız sunucu 202 döndüğünde (ya da 429 dışı 4xx ile kalıcı reddedildiğinde) silinir; 5xx, 429 ve ağ hatasında diskte kalır ve aynı `event_id` ile yeniden denenir. Sonucu bilinmeyen batch'in sabitlenmesi bellektedir: yeniden başlatmadan sonra batch kuyruk başından yeniden kurulur, olay kimlikleri aynı kalır.
- Üst sınır `queueLimit` (varsayılan 1000): dolunca en eski olay atılır; geri yüklemede de aynı sınır uygulanır.
- Dosya bozuksa sessizce sıfırlanır ve boş kuyrukla başlanır; JSON nesnesi olmayan ya da tekrar eden satırlar atılır. İlk kurulumda dosya yoktur, kuyruk boş başlar. Disk yazım hatası uygulamayı düşürmez, bellekteki kuyruk çalışır.
- Açılışta `consent.analytics` kapalıysa diskteki kuyruk ve oturum silinir, gönderilmez; izin geri çekilince de silinir. Uygulama her açılışta gerçek izin değerini vermelidir.
- Oturum: olaylara `session_id` otomatik yazılır (`sessionID` açıkça verilirse o geçer). Son etkinlikten `sessionTimeout` (varsayılan 30 dk, Android ve Flutter ile aynı) geçmişse yeni oturum başlar; kontrol `track`, `willEnterForeground()` ve `didEnterBackground()` çağrılarında yapılır. Son etkinlik zamanı diske yazıldığından süreç yeniden başlayınca da kural işler: 30 dk içinde açılırsa oturum sürer. `reset()` yeni oturum başlatır. `willEnterForeground()` ve `didEnterBackground()` uygulamanın yaşam döngüsü bildirimlerinden çağrılır; SDK bildirimlere kendiliğinden abone olmaz.

## Oyun olayları, reklam geliri ve hata (X4)

Sözleşme Android, Flutter, React Native ve Unity ile birebir aynıdır (`packages/schemas/utp/v1/event.schema.json`, `game-events.md`). Sözleşme dışı girdide `nil` döner ve olay üretilmez; istemci kapalıysa `FeralinError.clientClosed` fırlatılır.

```swift
try await client.trackLevelStart("1-3", attempt: 2)
try await client.trackLevelComplete("1-3", score: 900, durationMillis: 41_000)
try await client.trackEconomySource("gold", amount: 50, reason: "quest")   // sanal para, gerçek gelir değil
try await client.trackAdRevenue(AdRevenueInput(network: "admob", adFormat: .rewarded, revenueMicros: 12_500, currency: "USD"))

try await client.captureError(error, appVersion: "1.2.3")                  // fr_error
await client.captureUncaughtExceptions(appVersion: "1.2.3")                // yakalanmamış NSException
```

- **Reklam geliri:** `fr_ad_revenue`, `revenue_micros` para biriminin milyonda biri ve tam sayıdır; satın alma gelirine ve reklam harcamasına karışmaz, istemci beyanıdır, sunucuda ESTIMATED kalır.
- **Hata:** gider: hata türü adı, temizlenmiş mesaj, normalize çerçeve özeti `fingerprint` (adres, kaydırma ve yol gitmez; sistem modülleri uygulama çerçevesi varsa parmak izine girmez), `top_frame`, `app_version`. Ham yığın izi gitmez. İstemci başına en çok 20 olay, aynı parmak izi için 3; `configureErrorCapture(sampleRate:)` örnekleme verir. `captureUncaughtExceptions` yalnız Objective-C `NSException`'ı yakalar ve önceki işleyiciyi çağırmaya devam eder; Swift çalışma zamanı hataları ve sinyal çökmeleri yakalanmaz.
- **Sembolleştirme (dSYM):** hata olayına uygulama görüntülerine düşen en çok 5 çerçevenin konumu `frames` olarak eklenir: `file` = `<modül>~<uuid>` (modül görüntünün dosya adı, izinsiz karakterler `_`; UUID görüntünün `LC_UUID` değeri, küçük harf ve tiresiz), göreli adres `line` ve `column`'a bölünür (`line = adres / 10.000.000 + 1`, `column = adres % 10.000.000`). Ham bellek adresi, dosya yolu ve işlev adı gitmez; sistem görüntüleri (`/System/`, `/usr/lib/`) atlanır. Sürümün dSYM'sini yükleyin; panel çerçeveyi okuma anında işlev adı, kaynak dosyası ve satıra çözer. Eşleşme UUID iledir: başka derlemenin dSYM'si uygulanmaz. Yükleme `symbols:write` yetkili gizli API anahtarıyla (proje anahtarı yükleyemez); Xcode'da yayın derlemesine **Run Script** adımı olarak (anahtar ortam değişkeninden okunur, dosyaya yazılmaz; `--url-query` curl 7.87+ ister, macOS 14 ve üstünde var):

```bash
for dwarf in "$DWARF_DSYM_FOLDER_PATH"/*.dSYM/Contents/Resources/DWARF/*; do
  base64 -i "$dwarf" | curl --fail-with-body -X POST "https://feralin.com/api/v1/projects/$FERALIN_PROJECT_ID/dsyms" \
    --url-query "module=$(basename "$dwarf")" --url-query "release=$MARKETING_VERSION" \
    -H "Authorization: Bearer $FERALIN_SYMBOLS_KEY" -H "X-Feralin-Upload: dsym" \
    -H "Content-Type: text/plain" --data-binary @-
done
```

  Bitcode ya da App Store işlemesiyle dSYM değiştiyse App Store Connect'ten indirilen dSYM aynı komutla yüklenir. Çok mimarili (fat) dSYM mimari başına ayrı kayda bölünür. Dosya en çok 48 MiB, varsayılan 90 gün saklanır.
- **Durum:** `Signals.swift`, `AppleFrames.swift` ve `SignalsTests.swift` yazıldı, macOS'ta DERLENMEDİ ve KOŞULMADI. Sözleşme mantığı Android ve React Native'deki birim testli karşılıklarla aynıdır. Sunucu tarafı (dSYM yükleme, UUID eşleşmesi, `llvm-symbolizer` çözümü) gerçek arm64 dSYM ile sınandı (`services/saas-api/test/fixtures/feralin-dsym-fixture.c`, Mac olmadan NDK LLVM araçlarıyla üretildi); SDK'nın cihazda ürettiği çerçeve sınanmadı.

## Satın alma geliri: trackRevenue ve StoreKit 2

Sözleşme Android, Flutter ve Web ile aynıdır: olay `feralin_purchase`, tutar küçük birimde tam sayı (`amount_minor`, 49,99 TRY için 4999), para birimi ISO 4217, `purchase_type` `purchase`, `subscription_start`, `subscription_renew` ya da `subscription_cancel` (tutar 0). İstemci beyanıdır: `verified` hiçbir zaman gönderilmez, çağıranın verdiği `verified` ve türevleri düşürülür.

```swift
// Elle beyan (StoreKit dışı ödeme ya da kendi sunucunuzun onayladığı sipariş)
try await client.trackRevenue(RevenueInput(transactionID: "ord_1", amountMinor: 4999, currency: "TRY", productID: "pro"))

// Ondalık tutarla (StoreKit Product): küçük birime sunucuyla aynı kuralla çevrilir
try await client.trackRevenue(amount: product.price, currency: product.priceFormatStyle.currencyCode,
                              productID: product.id, transactionID: String(transaction.id),
                              receipt: PurchaseReceipt(provider: .apple, token: verification.jwsRepresentation))

// StoreKit 2: uygulama içi satın alma sonucu (aynı cihazda purchase() dönen işlem Transaction.updates akışına düşmez)
let result = try await product.purchase()
try await client.trackStoreKitPurchase(result, product: product)

// StoreKit 2: Transaction.updates dinleyicisi (varsayılan kapalı; uygulama açılışında, en erken anda kurun)
let client = try FeralinClient(configuration: .init(
    projectKey: "pk_live_...",
    collectURL: "https://collect.example.com",
    consent: Consent(analytics: true),
    storageDirectory: FeralinClient.defaultStorageDirectory(),
    captureStoreKitTransactions: true
))
```

- **Tutar ve küçük birim:** StoreKit işleminde önce işlemin kendi fiyatı (`Transaction.price`, teklif ve indirim yansır) ve para birimi (`Transaction.currency`, iOS 16+) okunur; iOS 15'te para birimi, işlemde fiyat yoksa tutar ürün kataloğundan (`Product.price`, `priceFormatStyle.currencyCode`) tamamlanır. Küçük birim üssü sunucudaki kuralla aynıdır (JPY, KRW gibi 10 para birimi 0; BHD, JOD, KWD, OMR, TND 3; öteki 2), yarım değer yukarı yuvarlanır. Apple belgesine göre tüketilebilir üründe `Transaction.price` adet toplamıdır; SDK yeniden çarpmaz.
- **Tür:** otomatik yenilenen abonelikte ilk işlem (`id == originalID`) `subscription_start`, sonrakiler `subscription_renew`; öteki ürünler `purchase`. Olaya `original_transaction_id`, `product_kind`, `store` ve iOS 16+ `store_environment` (Production, Sandbox, Xcode) eklenir.
- **Gönderilmeyenler:** `VerificationResult.unverified` (Apple imzası doğrulanmadı), iade ya da hak iptali (`revocationDate`), üst aboneliğe geçilmiş eski işlem (`isUpgraded`), aile paylaşımıyla gelen hak (`ownershipType == .familyShared`: ödemeyi bu kullanıcı yapmadı). Sonuç `StoreKitCaptureOutcome` ile döner.
- **İade:** sunucunun istemci olayı sözleşmesinde iade türü yoktur; iade ve geri ödeme App Store Server Notifications V2 (`POST /v1/finance-notifications/apple`) ile, imzası doğrulanarak deftere yazılır. Bu bildirim adresini App Store Connect'te tanımlayın.
- **Tekrar engeli:** aynı işlem (aynı `transaction_id` ve tür) bu kurulumda ikinci kez kuyruğa girmez; `trackRevenue` `nil`, StoreKit yolu `.duplicate` döner. Kayıt en çok 512 işlemdir ve `storageDirectory` verilirse diske (`feralin-purchases-v1.json`) yazılır. Verilmezse kuyruk gibi yalnız bellektedir: yeniden açılışta StoreKit bitmemiş işlemi yeniden bildirirse olay yeniden gider ve sunucu `transaction_id` ile tekilleştirir (olay kaybı yerine tekrar seçildi). Analitik izni geri çekilince kayıt silinir.
- **İşlemi bitirmek:** SDK `transaction.finish()` çağırmaz; içeriği teslim edip işlemi bitirmek uygulamanındır.
- **REAL_VERIFIED için sunucu tarafı:** satır yalnız sunucu Apple'dan işlemi doğrularsa REAL_VERIFIED olur. Gerekenler: panelde projenin Apple mağaza bağlantısı (bundle id, issuer id, key id ve uygulama içi satın alma anahtarı `.p8`; App Store Server API) ve sunucuda Apple Root CA - G3 (`APPLE_ROOT_CA_PEM_PATH`). Olay `receipt` (`provider: apple`) taşıyorsa toplayıcı `receipt_provider` ve belirtecin SHA-256 özetini yazar; sunucu `GET /inApps/v1/transactions/{transaction_id}` ile işlemi Apple'dan çeker, bundle, ürün, para birimi ya da tutar tutmazsa satır UNKNOWN olur. Makbuz yoksa ya da doğrulayıcı kurulmamışsa satır ESTIMATED kalır. Ham JWS olay deposuna yazılmaz; 8192 karakteri aşan JWS makbuz olarak gönderilmez.
- **Durum:** saf katman (`Revenue.swift`: sözleşme, küçük birim, tekrar engeli, StoreKit işlem eşlemesi) Linux'ta XCTest ile geçti (20 Kasım 2026). StoreKit 2 köprüsü (`StoreKitCapture.swift`, `#if canImport(StoreKit)`) Xcode'da DERLENMEDİ ve gerçek StoreKit işlemiyle (sandbox ya da StoreKit Testing) KOŞULMADI: Mac gerekir.

## SKAN dönüşüm değeri modülü (SKAdNetwork 4 ve AdAttributionKit)

Kiracının paneldeki SKAN şemasını (hangi olay hangi ince ve kaba değeri üretir) sunucudan alır ve izlenen olaylara göre `SKAdNetwork.updatePostbackConversionValue(_:coarseValue:lockWindow:)` (iOS 16.1+) ile `Postback.updateConversionValue(_:coarseConversionValue:lockPostback:)` (AdAttributionKit, iOS 17.4+) çağırır. Varsayılan kapalıdır; uygulama ayarıyla açılır.

```swift
let client = try FeralinClient(configuration: .init(
    projectKey: "pk_live_...",
    collectURL: "https://collect.example.com",
    consent: Consent(analytics: kullaniciAnalitikIzniVerdi),
    attribution: AttributionConfiguration(apiURL: "https://api.example.com", projectID: "proj_..."),
    storageDirectory: FeralinClient.defaultStorageDirectory(),
    skan: SkanConfiguration(frameworks: .both)
))
try await client.track("sign_up")       // şemada varsa dönüşüm değeri güncellenir
await client.refreshSkanSchema()       // panelde şema değişince hemen uygulamak için (isteğe bağlı)
```

- **Şema:** `GET {api}/v1/projects/{id}/skan/conversion-schema/sdk` (proje anahtarı `Authorization: Bearer`); en çok 24 saatte bir yenilenir (`schemaRefreshInterval`), arada diskteki kopya kullanılır. Şema kaydedilmemişse (`revision: null`) değer gönderilmez. `attribution` verilmeden modül açılırsa kurulum `FeralinError.configuration` fırlatır.
- **Kural (sunucuyla aynı, `skan-schema.ts`):** seçim `highest_value`: değer hiç düşmez; ince değerde sayı, kaba değerde low < medium < high. Pencereler 0-2, 3-7 ve 8-35. gün; ince değer yalnız ilk pencerede gider (sonrakilerde 0 gönderilir, Apple yok sayar). `lock_window` kuralı o pencereyi kilitler, pencere bitene kadar başka çağrı yapılmaz. 35. günden sonra çağrı yapılmaz. Apple yalnız değer arttığında ya da kilit istendiğinde çağrılır; çağrılar sırayla yapılır.
- **Kurulum kaydı:** Apple "uygulama ilk açıldığında kurulumu kaydetmek için çağırın" dediğinden modül ilk çalıştığında bir kez ince 0 ve kaba `low` gönderir; pencereler bu andan sayılır. Panelde ince değer 0 ya da yalnız kaba `low` değerine anlamlı bir olay eşlemeyin: kural olayı görülmemiş kurulum da bu değerle görünür.
- **İzin:** SKAN ve AdAttributionKit ATT izni istemez ve kişi tanımlamaz; modül analitik ve reklam izninden bağımsız çalışır (olay izin yüzünden kuyruğa girmese de değer güncellenir). Çağrı Apple'a gider, Feralin'e olay verisi gitmez. `childDirected: true` ise modül çalışmaz. Elle `updateConversionValue` yöntemi eskisi gibi reklam izni ister.
- **Kalıcılık:** durum (kayıt anı, pencere değerleri, şema) `storageDirectory` varsa `feralin-skan-v1.json`, yoksa `UserDefaults` içinde tutulur. Kişi verisi yoktur.
- **Sonuç:** `lastSkanUpdate` son çağrının sonucudur; `called` yalnız çağrının hatasız döndüğünü söyler, atıf gerçekleştiği anlamına gelmez. Postback çözümü sunucuda topludur ve ESTIMATED'dır; kesin tekil atıf iddia edilmez.
- **Durum:** karar mantığı, şema çözümü, kalıcılık ve sunucu isteği Linux'ta XCTest ile (sahte Apple çağrısıyla) geçti (20 Kasım 2026). Gerçek `SKAdNetwork` ve `AdAttributionKit` çağrıları (`ApplePlatform.swift`, `#if canImport(StoreKit) && os(iOS)`) Xcode'da DERLENMEDİ ve cihazda KOŞULMADI; gerçek postback için Apple Ads ya da SKAN destekli ağ kampanyası gerekir (`BLOCKED_EXTERNAL`).

## Ağ

`URLSessionTransport` yönlendirme izlemez, proje anahtarı başka adrese taşınmaz; 3xx kalıcı olmayan hata sayılır, olaylar kuyrukta kalır. Yanıt gövdesi indirme sırasında 64 KB ile kesilir. `URLSessionTransport(session:)` verilen oturumun yalnız yapılandırmasını kullanır, o oturumun delegesi çağrılmaz; özel ağ yığını için `Transport` uygulanır.

## Desteklenmeyenler

- Kuyruk şifreli değildir; `storageDirectory` verilmezse bellektedir ve süreç ölünce kaybolur. Kalıcı kuyruk ve oturum kodu yazıldı, derlenmedi ve koşmadı.
- `page`, `screen`, OTel yok. Hata, oyun, reklam geliri ve satın alma geliri yöntemleri vardır. StoreKit 1 (`SKPaymentQueue`) otomatik yakalanmaz: `trackRevenue` ile verin.
- İade ve hak iptali istemciden gönderilmez (sunucunun istemci olayı sözleşmesinde iade türü yok); iade sunucuya App Store Server Notifications V2 ile gelir.
- Tel `platform` değeri iOS ve visionOS'ta `ios`, macOS, tvOS, watchOS'ta `other`: UTP şemasında ayrı değer yok.
- Yaşam döngüsü bildirimleri otomatik izlenmez; `willEnterForeground()` ve `didEnterBackground()` çağırmak, arka plana geçerken `flush()` çağırmak uygulamanındır.

## Kimlik yöntemleri (UTP §8.2)

```swift
await client.setGlobalProperties(["app_release": .string("2.4.0")])          // fr_ ile başlamayan her olaya eklenir
try await client.setUserProperties(["plan": .string("pro"), "seats": .int(12)]) // fr_user_properties
try await client.group("acme-team", traits: ["plan": .string("team")])          // fr_group
await client.clearGlobalProperties()
```

Kurallar diğer SDK'larla ve toplayıcıyla aynıdır (`Profile.swift`): anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, çağrı başına en çok 50 özellik, değer dizge (≤256 karakter, e-posta biçimi değil), sonlu sayı ya da mantıksal; kişisel veriye benzeyen anahtar ve `verified` gibi doğrulama alanları düşer; `group_id` 1-128 karakter, `@` ve kontrol karakteri içermez; global özellikte `.null` anahtarı siler, toplam en çok 50 anahtar, `reset()` globalleri de siler. Kod ve `ProfileTests.swift` macOS, Xcode ve `swift` olmadan yazıldı: **derlenmedi, testler koşmadı** (`NOT_RUN`, Mac M1 gerekir).

## Geliştirme

macOS ya da Swift araç zincirli Linux üzerinde:

```bash
cd sdks/swift
swift build
swift test
DATABASE_URL='postgres://KULLANICI:PAROLA@127.0.0.1:5432/TEST_VERITABANI?sslmode=disable' node ../../scripts/sdk-e2e/run.mjs ios-swift
```

İlk derlemede bakılacak riskler (doğrulanamadı):

1. iOS 14.0-14.2'de açılış: AdServices 14.3 ile gelir. Tüm sembolleri yeni sürüm erişimli olduğundan bağlayıcının çerçeveyi zayıf bağlaması beklenir; gerçek cihaz ya da simülatörde denenmeli.
2. `AdAttributionKit` için Xcode 15.3 ve üstü gerekir; eski SDK'da `canImport` yanlış döner ve `notSupported` çalışır.
3. Linux'ta `FoundationNetworking` ile derlenmesi amaçlandı, denenmedi.
4. `FeralinApple.adServicesToken` ve `updateConversionValue` `@usableFromInline` oldu; `FeralinClient.init` varsayılan bağımsız değişkenlerinin bunlara başvurması derleyiciyle doğrulanmadı.

## Dolandırıcılık işaretleri: SDK imzası, kurulum kaynağı ve simülatör

```swift
let client = try FeralinClient(configuration: .init(
    projectKey: "pk_live_...",
    collectURL: "https://feralin.com/collect",
    signingKey: SigningKey(id: "sgn_...", secret: "fsk_...")
))
try await client.trackFirstOpen(installStore: await FeralinInstallSource.current())
```

- `signingKey` verilirse `app_first_open` ve `deep_link_opened` olayları imzalanır (`fr_sig`, HMAC-SHA256; saf Swift, bağımlılık yok).
  Anahtar panelde **Sahtecilik > Dolandırıcılık kuralları** altında üretilir ve yalnız bir kez gösterilir. Uygulamaya gömülü anahtar
  paketten çıkarılabilir: imza sahte kurulumu zorlaştırır, imkânsız kılmaz.
- `FeralinInstallSource.current()` kurulum kaynağını döner: `app_store`, `testflight`, `alt_marketplace`, `web_distribution`, `enterprise`,
  `simulator`. Apple bu bilgiyi yalnız iOS / iPadOS 17.4 ve sonrasında verir (`AppDistributor.current`, MarketplaceKit); daha eski sürümde
  ve öteki Apple platformlarında `nil` döner ve olaya alan eklenmez (tahmin yürütülmez). Alternatif pazar yerinin kimliği gönderilmez.
- Simülatörde derlenmiş uygulama ilk açılışa `device_emulator: true` ekler (derleme zamanında bilinir; cihazdan veri okunmaz).
- Jailbreak'li görünen iPhone / iPad ilk açılışa `device_rooted: true` ekler (`FeralinInstallSource.isJailbroken`: bilinen jailbreak dosyalarının
  varlığı; yalnız iOS, simülatör hariç). Tek bir evet/hayır değeridir; kendini gizleyen jailbreak'i görmez. Gerçek cihazda denenmedi.
- Linux'ta derlenip test edilen kısım: imza, SHA-256/HMAC vektörleri, kapalı liste. `AppDistributor` ve simülatör dalı yalnız Mac'te
  derlenir; gerçek iPhone'da doğrulanmadı (`docs/MAC_GOREVLERI.md` M18).

## Çocuklara yönelik uygulama ve izin süresi

```swift
let client = try FeralinClient(configuration: .init(
    projectKey: "pk_live_...",
    collectURL: "https://feralin.com/collect",
    childDirected: true,                          // COPPA ve benzeri kurallar
    consentMaxAgeDays: 180,
    advertisingConsentGrantedAt: savedConsentDate // iznin verildiği an; uygulama saklar
))
```

- `childDirected: true`: reklam ölçümü ve kişiselleştirme izni her zaman kapalıdır; tıklama kimliği, pano ve AdServices kullanılmaz.
  Panelde **SDK Merkezi > Gizlilik ayarları** altındaki "Çocuklara yönelik uygulama" ayarını da açın.
- İzin süresi: bu SDK kalıcı izin durumu tutmaz; iznin verildiği anı uygulama saklar ve yapılandırmada ya da
  `setConsent(_:grantedAt:)` ile verir. Süre dolmuşsa `advertisingConsentExpired` true olur ve olaylar reklam izni kapalı gider.
- Apple gizlilik etiketi için panelde **SDK Merkezi > Mağaza gizlilik beyanı yardımcısı** projenin ayarlarına göre veri türlerini listeler.

## İşletim sistemi sürümü (reklam ağına uygulama olayı)

`trackFirstOpen` Apple platformlarında ilk açılışa `os_version` ekler (`ProcessInfo.operatingSystemVersion`, ör. `17.4.1`). Cihaz kimliği
değildir. Panelde bir Meta dönüşüm hedefi açıksa sunucu bu kurulumun olaylarını Meta'ya uygulama olayı olarak gönderirken bu değeri
kullanır; sürümü bildirmeyen kurulumun uygulama olayı gönderilmez. Gerçek iPhone'da denenmedi.

## İsteğe bağlı reklam kimliği (IDFA)

SDK AdSupport'a bağlanmaz ve IDFA'yı kendisi okumaz. Uygulama ATT izni `authorized` olduktan sonra kimliği verir:
`try client.trackFirstOpen(advertisingID: ASIdentifierManager.shared().advertisingIdentifier.uuidString)`. Kimlik yalnız reklam ölçümü
izni açıksa, `childDirected` kapalıysa ve değer sıfırlanmamış bir UUID ise gönderilir. Sunucu onu yalnız panelde projenin
"Reklam kimliği" ayarı da açıksa saklar, yalnız reklam ağına dönüşüm iletiminde (Meta `madid`) kullanır ve 90 gün sonra siler.
Uygulamanın gizlilik etiketini ve gizlilik bildirim dosyasını güncelleyin. Gerçek iPhone'da denenmedi.

## Push açılışı ve e-posta (ESP) bağlantıları

- `try client.trackPushOpen(userInfo: response.notification.request.content.userInfo)`: kullanıcı bildirime dokunarak açınca (`fr_push_open`).
  Yalnız `utm_*` ve `fr_push_id` gider; kampanya bilgisi yoksa `utm_medium=push`. Kaldırma ölçümü bildirimi açılış sayılmaz.
- `let url = await FeralinClient.resolveTrackedLink(incoming)`: Universal Link bir ESP tıklama alanından geldiyse sarılı adresi Feralin kısa
  linkine çözer; sonucu `handleUniversalLink(_:)` ile işleyin. ESP alanının `apple-app-site-association` dosyasını sunması ESP'nin ayarıdır.
  Gerçek iPhone'da ve gerçek ESP ile denenmedi.
