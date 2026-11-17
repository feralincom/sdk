# Feralin Objective-C köprüsü

`sdks/swift` paketine `@objc` köprü. Ayrı SPM paketi ve ayrı hedeftir (`FeralinObjC`); bütün davranış Swift `FeralinClient` aktöründedir, burada yalnız tür çevrilir. Tel üzerindeki `sdk.name` değeri `feralin-objc`.

## Durum

| Konu | Durum |
|---|---|
| Kod ve testler | **Yazıldı, hiç derlenmedi ve hiç koşmadı.** Bu makinede macOS, Xcode ve `swift` yok. `lifecycle: IMPLEMENTING` |
| `swift build`, `swift test` | `NOT_RUN` |
| Gerçek `services/collect` | `scripts/sdk-e2e/targets/objc.mjs` yazıldı, `NOT_RUN`; `@objc` yalnız Apple platformunda vardır, macOS gerekir |
| Yayın | `BLOCKED_EXTERNAL`: herkese açık Git deposu yok |

## Kurulum

```swift
.package(path: "../sdks/objc")
// hedef bağımlılığı
.product(name: "FeralinObjC", package: "FeralinObjC")
```

## En kısa örnek

```objc
@import FeralinObjC;

FRLConfiguration *ayar = [[FRLConfiguration alloc] initWithProjectKey:@"pk_live_..."
                                                           collectURL:@"https://collect.example.com"];
ayar.consent = [[FRLConsent alloc] initWithAnalytics:YES advertising:NO personalization:NO sessionReplay:NO];

NSError *hata = nil;
FRLFeralin *feralin = [[FRLFeralin alloc] initWithConfiguration:ayar error:&hata];

[feralin track:@"order_completed"
    properties:@{@"order_id": @"ord_1", @"amount": @249.9}
    completion:^(NSString *eventID, NSError *error) { /* izin yoksa ikisi de nil */ }];

[feralin flushWithCompletion:^(FRLFlushResult *sonuc, NSError *error) {
    if (sonuc.ok) { /* sonuc.accepted, sonuc.batchID */ }
}];
```

Tamamlama blokları ana iş parçacığında çağrılmaz. `properties` değerleri `NSString`, `NSNumber`, `NSNull`, `NSArray`, `NSDictionary` olmalı; başka tür `FRLErrorCodeInvalidEvent` döner, uygulama düşmez.

## İzin ve attribution

Kurallar Swift SDK ile aynıdır: `analytics` yoksa olay üretilmez, `advertising` yoksa `fr_click` çıkarılır ve Apple çağrıları yapılmaz. ATT istemcide zorlanır: `denied`, `restricted` ve `notDetermined` iken `advertising: YES` verilse bile reklam izni kapalı sayılır (ayrıntı: `sdks/swift/README.md`). SDK ATT penceresi göstermez, panoyu okumaz, parmak izi toplamaz. Kesin attribution garanti edilmez.

Çağrılar geldiği sırayla işlenir: `setConsent` ardından gelen `track` izin değişiminden sonra çalışır. Tamamlama bloklarının kendi aralarındaki sırası garanti değildir.

```objc
FRLTrackingAuthorizationStatus durum = [FRLFeralin trackingAuthorizationStatus];
[feralin setConsent:[kullaniciIzni constrainedByTrackingStatus:durum] completion:nil];

[feralin submitAdServicesTokenWithCompletion:^(FRLAttributionResult *r) { /* r.outcome: exchange_blocked, not_stored, skipped_no_consent... */ }];

// Yalnız kullanıcı kodu kendisi girdiğinde:
[feralin redeemContinuityCode:girilenKod completion:^(FRLAttributionResult *r) { /* confirmed, invalid_code, self_redeem... */ }];

[feralin updateConversionValue:12 coarse:FRLCoarseConversionValueMedium lock:NO
                    completion:^(NSString *adAttributionKit, NSString *skAdNetwork) { /* called, not_supported, skipped_no_consent */ }];
```

`apiURL` ve `projectID` ayarlanmamışsa attribution yöntemleri `not_configured` döner. `exchange_blocked` token'ın alındığını, Apple'a sorulmadığını söyler; atıf kararı değildir.

## Desteklenmeyenler

Swift SDK'nın eksikleri burada da geçerlidir: kalıcı kuyruk, `page`, `screen`, `group`, `setUserProperties`, `trackRevenue`, Universal Links, hata raporlama ve OTel yok. Köprüde özel taşıma ve özel `InstallIDStore` `@objc` yüzeyine açık değildir; Swift'ten `FRLFeralin(client:)` ile verilir.

## Geliştirme

macOS üzerinde:

```bash
cd sdks/objc
swift build
swift test
DATABASE_URL='postgres://KULLANICI:PAROLA@127.0.0.1:5432/TEST_VERITABANI?sslmode=disable' node ../../scripts/sdk-e2e/run.mjs objc
```

İlk derlemede bakılacak risk: `FeralinObjCHeaderTests` Objective-C hedefi `@import FeralinObjC` ile SwiftPM'in ürettiği modül haritasına dayanır; bu yol denenmedi.
