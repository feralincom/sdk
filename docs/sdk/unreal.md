<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Unreal C++: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/unreal/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | C++ |
| Paket | `Feralin` |
| Sürüm | 0.2.0 |
| Yaşam döngüsü | IMPLEMENTING |
| Kaynak dizin | `sdks/unreal` |
| Registry | Fab / UE eklenti yayını: **BLOCKED_EXTERNAL** (gereken: Epic Fab satıcı hesabı ve Unreal Engine ile derlenmiş paket) |
| Test | `node sdks/unreal/tests/run.mjs` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `Fab / UE eklenti yayını` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```ini
[/Script/Feralin.FeralinSettings]
ProjectKey=pk_live_...
CollectUrl=https://collect.example.com
```

## İlk kullanım

```cpp
UFeralinSubsystem* Feralin = GetGameInstance()->GetSubsystem<UFeralinSubsystem>();

FFeralinConsent Consent;
Consent.bAnalytics = true;  // oyuncudan alınan izin; varsayılan kapalı
Feralin->SetConsent(Consent);

Feralin->TrackLevelStart(TEXT("forest_3"), 1);
Feralin->TrackRevenue(TEXT("tx_1001"), 4999, TEXT("TRY"), TEXT("gold_pack"), 1, EFeralinPurchaseType::Purchase, EFeralinReceiptProvider::None, TEXT(""), TMap<FString, FString>());
Feralin->Flush();  // isteğe bağlı; olaylar 2 saniyede bir otomatik gider
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | PARTIAL (UE ile DERLENMEDİ; saf mantık ve taklit başlıklı alt sistem g++ ile sınandı) |
| batch | PARTIAL (kalıcı kuyruk Saved/Feralin altında, olay gövdeleri AES-256-GCM ile şifreli, Unity ve Android ile aynı enc1 satır biçimi, aynı event_id ile tekrar gönderim, sınır ve eski olayı atma kuralı; yeniden başlatma testi g++ ile geçti; Android Keystore ve iOS Keychain anahtar köprüleri derlenmedi ve cihazda sınanmadı, diğer platformlarda anahtar dosyada (local_file); UE ile DERLENMEDİ) |
| consent | PARTIAL (izin kapısı, izin çekilince bellek ve disk kuyruğu silinir; UE ile DERLENMEDİ) |
| identity | PARTIAL (identify, reset, group ve setUserProperties fr_group ve fr_user_properties olayıdır, 30 dakikalık otomatik oturum; SDK anonymous_id üretmez; g++ ile sınandı, UE ile DERLENMEDİ) |
| attribution | PARTIAL (Android Play Install Referrer JNI köprüsü ve iOS AdServices token ile BindInstall; InstallCode → fr_install_code yalnız ilk olaya; çekirdek mantık g++ ile sınandı, köprüler derlenmedi ve cihazda sınanmadı; iOS kesin tekil atıf değildir, ATT reddi reklam kanıtını kapatır, parmak izi yok) |
| deeplink | PARTIAL (HandleDeepLink ile deep_link_opened ve fr_click bağlama, yalnız http(s), ham URL saklanmaz; Play referrer ile ertelenmiş yol teslimi; g++ ile sınandı, cihazda ve gerçek App Link ile sınanmadı) |
| revenue | PARTIAL (TrackRevenue → feralin_purchase istemci beyanı, Android Flutter RN Unity ile aynı kurallar; verified yalnız sunucuda; reklam geliri fr_ad_revenue ayrı olay (revenue_micros); oyun olayları game-events.md ile; 25 vektör Unity çıktısıyla birebir; UE ile DERLENMEDİ) |
| error | PARTIAL (fr_error olayı, CaptureError ve motor günlüğü Error kayıtları, PII temizliği, normalize çerçeve parmak izi, örnekleme ve hız sınırı; 146 vektör Unity çıktısıyla birebir; native çökme ve ANR yakalanmaz; UE ile DERLENMEDİ) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PARTIAL | Kod yazıldı; Unreal Engine ile derlenmedi. Saf mantık (kuyruk şifreleme, sözleşmeler, atıf) g++ ile derlendi, alt sistem yalnız taklit başlıklarla derlendi, Android (Java, UPL, JNI) ve iOS (.mm) köprüleri hiç derlenmedi. |
| build | NOT_RUN | Bu makinede Unreal Engine yok; UBT ve UHT koşmadı. |
| test | PARTIAL | node sdks/unreal/tests/run.mjs: tel biçimi 20 test (C++17 ve C++20, exception ve RTTI kapalı); şifreleme ve hata temizleme 250 denetim (NIST AES-256-GCM, SHA-256, Unity çıktılarından 146 temizleme ve 5 şifreli satır vektörü); oyun sözleşmeleri 142 denetim (25 gelir ve reklam geliri vektörü, kalıcı şifreli kuyruk yeniden başlatma, hata, oturum, atıf, BindInstall); alt sistem akışı 140 denetim UE taklit başlıklarıyla. Motor içinde test koşmadı. |
| registry | BLOCKED_EXTERNAL | Fab satıcı hesabı yok. |
| clean_install | NOT_RUN | Unreal Engine yok; eklenti bir projeye kurulmadı. |
| event_receipt | NOT_RUN | Unreal Engine yok; bu eklentiden toplayıcıya olay gitmedi (scripts/sdk-e2e/run.mjs unreal yazılmadı: çalıştıracak motor yok). Aynı tel biçimi yalnız sdks/cpp üzerinden doğrulandı; olay gövdesi alanları Unity çıktılarıyla vektör karşılaştırmasından geçti. |
| documentation | PASS | docs/sdk/unreal.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
