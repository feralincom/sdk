# Feralin Unreal Engine eklentisi (`Feralin`) — UTP v1

UE5 oyunlarından Feralin toplayıcısına (`POST /v1/batch`) olay gönderen eklenti: C++ modülü, `FHttpModule`, `UFeralinSubsystem` ve Blueprint düğümleri. Sözleşme Unity SDK 0.2.0 ile aynıdır.

## Durum (dürüst)

**Bu eklenti Unreal Engine ile HİÇ derlenmedi ve çalıştırılmadı.** Geliştirme makinesinde Unreal yoktur. `lifecycle: IMPLEMENTING`. Motor API'si kullanımı (`FTSTicker`, `IHttpRequest`, `UDeveloperSettings`, UHT makroları, JNI, UPL) yalnız bilgiye dayanır; ilk gerçek derleme hata verebilir.

| Konu | Durum |
|---|---|
| Saf mantık (`FeralinGame.hpp`, `FeralinCrypto.hpp`, `FeralinSanitize.hpp`, `FeralinSha256.hpp`) | g++ ile exception ve RTTI kapalı, `-Werror` ile derlenip sınandı: NIST AES-256-GCM ve SHA-256 vektörleri, Unity çıktılarından üretilmiş 146 hata temizleme vektörü, 5 şifreli satır, 25 gelir ve reklam geliri vektörü, kalıcı şifreli kuyruk, hata, oturum, atıf, `BindInstall` |
| Tel biçimi (`FeralinWire.hpp`) | `sdks/cpp/include/feralin/wire.hpp` ile birebir aynı dosya; 0.2.0'da `EventCore::restore` eklendi (kalıcı kuyruktan aynı `event_id` ile geri yükleme) |
| `UFeralinSubsystem` akışı | **UE taklit başlıklarıyla** (`tests/ue_stub/ue_stub.h`) g++ ile derlenip sınandı. Kendi kodumuzun mantığını sınar, motoru kanıtlamaz |
| Android köprüsü (`Private/Android`: Keystore, Play Install Referrer, UPL) | Yazıldı, **derlenmedi**, cihazda sınanmadı |
| iOS köprüsü (`Private/IOS/FeralinNative.mm`: Keychain, AdServices, ATT) | Yazıldı, **derlenmedi**, cihazda sınanmadı |
| UE Build Tool, UHT, Editor, Blueprint, gerçek `FHttpModule` | Koşmadı |
| Gerçek `collect` ile uçtan uca (`node scripts/sdk-e2e/run.mjs unreal`) | Koşmadı: Unreal yok. Aynı tel biçimi `sdks/cpp` üzerinden gerçek toplayıcıda sınandı |
| Yayın (Fab / Git release) | **`BLOCKED_EXTERNAL`** |

## Kurulum

`Feralin/` dizinini oyun projenizin `Plugins/` altına kopyalayın, projeyi yeniden derleyin ve Editor'de eklentiyi etkinleştirin.

Proje Ayarları içindeki Feralin bölümü veya `Config/DefaultGame.ini`:

```ini
[/Script/Feralin.FeralinSettings]
ProjectKey=pk_live_...
CollectUrl=https://collect.example.com
```

`ProjectKey` yalnız public anahtardır (`pk_`). `sk_` reddedilir. Geçersiz ayarda oyun düşmez; alt sistem kapalı kalır ve `LogFeralin` kategorisine uyarı yazar.

## En kısa örnek

C++:

```cpp
UFeralinSubsystem* Feralin = GetGameInstance()->GetSubsystem<UFeralinSubsystem>();

FFeralinConsent Consent;
Consent.bAnalytics = true;  // oyuncudan alınan izin; varsayılan kapalı
Feralin->SetConsent(Consent);

Feralin->TrackLevelStart(TEXT("forest_3"), 1);
Feralin->TrackRevenue(TEXT("tx_1001"), 4999, TEXT("TRY"), TEXT("gold_pack"), 1, EFeralinPurchaseType::Purchase, EFeralinReceiptProvider::None, TEXT(""), TMap<FString, FString>());
Feralin->Flush();  // isteğe bağlı; olaylar 2 saniyede bir otomatik gider
```

Blueprint: `Get Game Instance Subsystem` (sınıf `FeralinSubsystem`), ardından `Set Consent`, `Track`, `Flush`. Flush sonucu `On Flush Completed` olayıyla gelir.

| Düğüm | Görev |
|---|---|
| `Track`, `TrackWithNumbers`, `TrackJson` | Serbest olay |
| `TrackRevenue` | `feralin_purchase`: istemci beyanı, `verified` gönderilmez, tutar tam sayı küçük birim |
| `TrackAdRevenue` | `fr_ad_revenue`: `RevenueMicros` (para biriminin milyonda biri), satın alma gelirinden ayrı |
| `TrackLevelStart/Complete/Fail`, `TrackEconomySource/Sink`, `TrackRewardedAdShown/Complete`, `TrackIapOfferShown/Initiated` | Oyun olayları (`packages/schemas/utp/v1/game-events.md`); verilmeyen isteğe bağlı sayı için -1, metin için boş |
| `Group`, `SetUserProperties` | `fr_group`, `fr_user_properties` |
| `CaptureError` | `fr_error`: kişisel veri ayıklanır, çerçeveler normalleştirilir, örnekleme ve dakikalık hız sınırı |
| `HandleDeepLink`, `ConsumeDeferredDeepLink` | `deep_link_opened`; Android Play Install Referrer'dan ertelenmiş yol |
| `BindInstall` | iOS AdServices token'ı + rastgele kurulum kimliği (`OnInstallBound`) |
| `SetConsent`, `GetConsent`, `Identify`, `SetAnonymousId`, `Reset` | İzin ve kimlik |
| `Flush`, `GetQueueLength` | Gönderim, kuyruk boyu |

Bütün çağrılar oyun iş parçacığından yapılmalıdır.

## İzin

- Varsayılan kapalıdır. `bAnalytics` false iken hiçbir olay üretilmez ve çağrılar `false` döner.
- İzin çekilince bekleyen olaylar ve diskteki kuyruk silinir. Karar verilmeden `HandleDeepLink` ile gelen bağlantı bellekte bekletilir.
- Reklam kanıtı (`fr_click`, `utm_*`, Install Referrer, AdServices) yalnız `bAdvertising` ve (iOS'ta) ATT reddetmemişse kullanılır.
- İzni oyuncudan almak ve saklamak oyunundur; eklenti izin ekranı açmaz, izni diske yazmaz. Her açılışta `SetConsent` çağrılmalıdır.

## Kalıcı şifreli kuyruk

Olaylar `Saved/Feralin/events.log` içinde AES-256-GCM ile şifreli tutulur (Android EncryptedEventStore ve Unity ile aynı satır biçimi: `enc1:` + hex(iv ‖ şifreli metin ‖ etiket), ilişkilendirilmiş veri olay kimliği). Süreç yeniden başlayınca izin verildiğinde aynı `event_id` ve aynı `Idempotency-Key` ile tekrar gönderilir; sunucu aynı olayı ikinci kez saymaz. Kuyruk sınırı (`QueueLimit`) diske de uygulanır; en eski olay atılır. Açılamayan satır atılır.

Veri anahtarı: Android'de Keystore, iOS'ta Keychain ile korunur (köprüler cihazda sınanmadı); diğer platformlarda `queue.key` dosyasında düz durur ve koruma düzeyi `local_file`dır (yalnız dosya izni). Anahtar alınamazsa düz metne düşülmez, kuyruk bellekte kalır. Anahtar rastgeleliği platform GUID üretecinden gelir. `bPersistQueue=false` ile kalıcılık kapanır.

## Teslim davranışı

Kurallar `sdks/cpp` ile aynıdır: `202` kabul; `401`/`403` bütün kuyruğu atar, oyun düşmez; öteki `4xx` (`429` hariç) o batch'i atar; `5xx`, `429` ve ağ hatası kuyrukta tutar ve aynı `Idempotency-Key` ile yeniden dener. Üstel geri çekilme 1 sn → 30 sn, `Retry-After` en az o kadar bekletir. Açık `Flush` geri çekilmeyi beklemez. Aynı anda tek istek açılır. Uygulama arka plana geçince gönderim denenir.

## Oturum, hata, atıf

- 30 dakikalık otomatik oturum (`SessionTimeoutMinutes`): arka planda süre dolarsa yeni `session_id`.
- `CaptureError` ve (`bCaptureLogErrors` açıksa) motor günlüğündeki Error kayıtları `fr_error` olur. Native çökme ve ANR yakalanmaz.
- Kurulum eşleştirme kodu: Proje Ayarları → Feralin → `InstallCode` ya da çalışma anında `SetInstallCode`. Panelin verdiği kod ilk üretilen olaya `fr_install_code` olarak eklenir ve o oturumda bir daha gönderilmez; biçime uymayan değer yok sayılır. Eşleşme bitince ayarı boşaltın.
- Android'de Play Install Referrer kurulumda bir kez okunur (`app_first_open`), iOS'ta `BindInstall`. iOS'ta kesin tekil atıf iddia edilmez; sunucu bugün Apple'a sormaz, token yalnız saklanır. Parmak izi yoktur; ham URL saklanmaz.

## Gizlilik

PII toplanmaz, cihaz veya donanım kimliği okunmaz, parmak izi yoktur. `tenant_id`, `project_id`, `verified` gönderilmez. Eklenti kimlik üretmez (kurulum kimliği hariç: rastgele ULID, yalnız reklam izniyle); `SetAnonymousId` için oyun kendi rastgele kimliğini verir. Anahtar loglara yazılmaz.

## Desteklenmeyenler

- UE4: `FTSTicker` ve `UFUNCTION` içinde `double` UE5 varsayar.
- Yönlendirme davranışı platformun HTTP katmanına bağlıdır; `CollectUrl` yönlendirmesiz son adres olmalıdır.
- Tracing, otomatik oyun olayı toplama, session replay.

## Geliştirme

Unreal gerektirmeyen denetimler (g++ ve Node):

```bash
node sdks/unreal/tests/run.mjs
```

Sırayla: `FeralinWire.hpp` kopya denetimi, eklenti tanımı ve sürüm tutarlılığı, saf tel biçimi testleri, oyun sözleşmeleri ve şifreli kuyruk (Unity vektörleri), taklit başlıklarla alt sistem akışı. `sdks/cpp/include/feralin/wire.hpp` değiştiyse dosyayı `Feralin/Source/Feralin/Private/FeralinWire.hpp` üzerine kopyalayın. Vektörler `tests/vectors/sdk_vectors.json` dosyasındadır ve Unity çekirdeğinden üretilmiştir.

Gerçek UE doğrulaması için gerekenler: Unreal Engine 5 kurulu makine; bir oyun projesinde `Plugins/Feralin`; `RunUAT BuildPlugin` ile derleme; Editor'de Blueprint düğümlerinin görünmesi; gerçek toplayıcıya olay gönderip `collect_outbox` satırında `platform=unreal` görmek; Android ve iOS cihazda köprülerin denenmesi.
