<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Objective-C: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/objc/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Swift, Objective-C |
| Paket | `FeralinObjC` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | IMPLEMENTING |
| Kaynak dizin | `sdks/objc` |
| Registry | SPM: **BLOCKED_EXTERNAL** (gereken: macOS, Xcode, Apple Developer ve public Git deposu (Git tag)) |
| Derleme | `cd sdks/objc && swift build` |
| Test | `cd sdks/objc && swift test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `SPM` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```swift
.package(path: "../sdks/objc")
// hedef bağımlılığı
.product(name: "FeralinObjC", package: "FeralinObjC")
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | PLANNED (#11 üzerinden köprü yazıldı, ÇALIŞTIRILMADI; BLOCKED_EXTERNAL) |
| batch | PLANNED (#11 üzerinden bellek içi kuyruk, ÇALIŞTIRILMADI; BLOCKED_EXTERNAL) |
| consent | PLANNED (#11 üzerinden, ATT durumu okunur, ÇALIŞTIRILMADI; BLOCKED_EXTERNAL) |
| identity | PLANNED (identify ve reset yazıldı, group ve setUserProperties yok; ÇALIŞTIRILMADI; BLOCKED_EXTERNAL) |
| attribution | PLANNED (#11 üzerinden AdServices, SKAdNetwork, AdAttributionKit, devam kodu; ÇALIŞTIRILMADI; kesin atıf yok; BLOCKED_EXTERNAL) |
| deeplink | PLANNED |
| revenue | PLANNED |
| error | PLANNED |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PARTIAL | FRLFeralin köprüsü, Swift ve Objective-C testleri yazıldı; hiç derlenmedi. Davranış sdks/swift çekirdeğindedir. |
| build | NOT_RUN | Bu makinede macOS, Xcode ve swift yok; @objc yalnız Apple platformunda derlenir. |
| test | NOT_RUN | swift yok; XCTest testleri yazıldı, koşmadı. |
| registry | BLOCKED_EXTERNAL | Public Git deposu ve Git tag yok. |
| clean_install | NOT_RUN | macOS yok; scripts/sdk-e2e/targets/objc.mjs yazıldı, koşmadı. |
| event_receipt | NOT_RUN | scripts/sdk-e2e/targets/objc.mjs yazıldı, macOS olmadığından koşmadı. |
| documentation | PASS | docs/sdk/objc.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
