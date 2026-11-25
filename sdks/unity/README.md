# Feralin Unity SDK

`com.feralin.unity`: Unity oyunları için UTP v1 olay SDK'sı. İzin yoksa olay üretmez, parmak izi veya cihaz kimliği toplamaz. Çalışma zamanı bağımlılığı yalnız Unity'nin kendi `UnityWebRequest` modülüdür (Android atfı için ayrıca Play Install Referrer kitaplığı, aşağıya bakın).

> **Durum:** Paket kanalı herkese açık Git deposudur (aşağıda); sürüm etiketi `sdks/unity/v0.3.0` yayında (19 Kasım 2026). Unity Asset Store kaydı yok. Android ve iOS yerel köprüleri (Keystore, Keychain, Install Referrer, AdServices) yazıldı ama oyuncu derlemesi ve cihaz olmadığı için **derlenmedi ve cihazda sınanmadı**. Ayrıntı için "Doğrulama" bölümüne bakın. Kurulum belgesi: [`docs/sdk/unity.md`](../../docs/sdk/unity.md) (TR ve EN).

## Kurulum

### Git deposundan (UPM)

Paket herkese açık depoda `sdks/unity` altındadır (<https://github.com/feralincom/sdk>); sürüm etiketi `sdks/unity/v0.3.0`. Unity Package Manager → **+** → **Add package from git URL** alanına:

```text
https://github.com/feralincom/sdk.git?path=sdks/unity#sdks/unity/v0.3.0
```

ya da `Packages/manifest.json`:

```json
{ "dependencies": { "com.feralin.unity": "https://github.com/feralincom/sdk.git?path=sdks/unity#sdks/unity/v0.3.0" } }
```

Bilgisayarda Git kurulu olmalıdır (Unity Git adresini kendisi değil, `git` komutuyla çeker). `#` sonrası etiket sürümü sabitler; etiketsiz adres `main` dalının o anki hâlini kurar ve önerilmez. Etiket depoya gönderilmeden adres "revision not found" hatası verir; yayımlanmış etiketler <https://github.com/feralincom/sdk/tags> sayfasındadır.

### Paket dosyasından (tarball)

Unity Package Manager → **Add package from tarball**, veya `Packages/manifest.json`:

```json
{ "dependencies": { "com.feralin.unity": "file:/mutlak/yol/com.feralin.unity-0.3.0.tgz" } }
```

Paket üretmek: `sdks/unity` içinde `npm pack`.

Android atfı için Google'ın `com.android.installreferrer:installreferrer:2.2` kitaplığı gerekir. Projede External Dependency Manager (EDM4U) varsa paketteki `Editor/FeralinDependencies.xml` bunu kendiliğinden ekler; yoksa `mainTemplate.gradle` içine `implementation 'com.android.installreferrer:installreferrer:2.2'` satırını ekleyin. Kitaplık yoksa SDK çökmez: referrer okunamaz ve ilk açılış `attribution_source=none` ile sayılır.

## En kısa örnek

```csharp
using Feralin.Unity;
using UnityEngine;

public class Game : MonoBehaviour
{
    void Start()
    {
        var feralin = FeralinBehaviour.Initialize("pk_live_ORNEK", "https://collect.ornek.com");
        // Karar oyunun izin ekranından gelir; SDK izni kendisi varsaymaz ve saklamaz.
        feralin.SetConsent(new Consent(analytics: true, advertising: true));

        feralin.Client.TrackLevelStart("dunya_1");
        feralin.Client.TrackLevelComplete("dunya_1", attempt: 1, score: 1200, durationMs: 33500);
    }
}
```

Bileşen sahneye `Feralin/Feralin` menüsüyle de eklenebilir; o durumda anahtar ve adres Inspector'dan girilir. Yalnız public `pk_` anahtarı kabul edilir, `sk_` reddedilir. Geçersiz yapılandırma oyunu düşürmez: hata Console'a yazılır, `Client` `null` kalır.

## İzin

- Başlangıçta hiçbir izin yoktur; `analytics=false` iken `Track` olay üretmez ve `null` döner.
- `Initialize` izin vermeden çağrılırsa istemci "karar yok" durumunda kalır: olay üretilmez, **diskteki kuyruk yüklenmez ve silinmez**. Oyun kararı `SetConsent` ile bildirince `analytics=true` kuyruğu yükler, `analytics=false` diskteki kuyruğu ve kimlik işaretlerini siler.
- `SetConsent(new Consent(false))` veya `Client.OptOut()` bekleyen kuyruğu da siler.
- `fr_click`, Play referrer, `utm_*` ve AdServices yalnız `advertising=true` iken kullanılır. iOS'ta ATT durumu `denied` ya da `restricted` ise reklam izni verilmiş olsa bile kullanılmaz.
- Analitik izniyle rastgele bir `anonymous_id` üretilir ve PlayerPrefs'te tutulur; izin geri çekilince ve `Client.Reset()` çağrısında silinir. `SystemInfo.deviceUniqueIdentifier` kullanılmaz.
- `Identify` için oyunun kendi oyuncu kimliğini verin; e-posta veya telefon vermeyin.

## Olay sözleşmesi (diğer mobil SDK'larla ortak)

| Yöntem | Olay | Özellikler |
|---|---|---|
| `TrackRevenue(RevenueInput)` | `feralin_purchase` | `transaction_id`, `amount_minor` (küçük birim, tam sayı), `currency` (ISO 4217), `quantity`, `purchase_type`, `product_id`, `receipt` |
| `TrackAdRevenue(AdRevenueInput)` | `fr_ad_revenue` | `network`, `ad_format`, `revenue_micros` (para biriminin milyonda biri), `currency`, `precision`, `ad_unit`, `placement`, `impression_id` |
| `Group(groupId, traits)` | `fr_group` | `group_id` ve özellikler |
| `SetUserProperties(props)` | `fr_user_properties` | özellikler |
| `CaptureError(...)` | `fr_error` | `error_type`, `message`, `fingerprint`, `top_frame`, `frame_count`, `app_version`, `handled`, `fatal`, `origin` |
| `TrackLevelStart / Complete / Fail` | `level_start`, `level_complete`, `level_fail` | `level_id`, `attempt`, `score`, `duration_ms`, `fail_reason` |
| `TrackEconomySource / Sink` | `economy_source`, `economy_sink` | `currency_name`, `amount`, `reason`, `item_id` |
| `TrackRewardedAdShown / Complete` | `rewarded_ad_shown`, `rewarded_ad_complete` | `placement`, `network`, `reward_amount`, `reward_currency` |
| `TrackIapOfferShown / Initiated` | `iap_offer_shown`, `iap_initiated` | `product_id`, `placement`, `transaction_id` (gelir değildir) |
| `TrackIapPurchase(...)` | `feralin_purchase` | Eski yardımcı (aşağıya bakın) |

### Gelir

`TrackRevenue` Android, Flutter ve React Native `trackRevenue` ile aynı kuralları uygular: tutar küçük birimde tam sayıdır (49,99 TL için `4999`), para birimi ISO 4217, işlem kimliği zorunludur, abonelik iptali `0` taşır; `verified`, `verification*`, `receipt_provider`, `receipt_digest` anahtarları özelliklerden düşürülür; sözleşme dışı girdide olay üretilmez ve `null` döner. **İstemci beyanıdır:** sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar, aksi halde ESTIMATED kalır. `Receipt` verilirse toplayıcı yalnız sağlayıcı adını ve belirtecin SHA-256 özetini saklar. Sunucu tarafı doğrulama için makbuzu/`purchaseToken`'ı kendi sunucunuzdan `POST /v1/projects/:id/finance/receipts/verify` ucuna gönderin.

```csharp
feralin.Client.TrackRevenue(new RevenueInput
{
    TransactionId = purchase.TransactionId,   // mağaza işlem kimliği
    AmountMinor = 4999,
    Currency = "TRY",
    ProductId = "gem_pack",
    Receipt = new Receipt(ReceiptProvider.Google, purchase.PurchaseToken),
});
```

`TrackIapPurchase(productId, price, currency, transactionId)` geriye uyumluluk için durur ve **artık `iap_purchase` olayı üretmez**: ondalık tutarı para biriminin küçük birimine çevirip `feralin_purchase` olarak gönderir. Sözleşme `transactionId` ister; boşsa olay üretilmez.

### Reklam geliri

`TrackAdRevenue` satın alma gelirinden ayrıdır; deftere `feralin_purchase` olarak girmez ve reklam ağlarının bildirdiği tahmini gelirdir (sunucu doğrulaması yok).

### Hata yakalama

`FeralinBehaviour` (varsayılan açık) `Application.logMessageReceivedThreaded` (istisna kayıtları; `captureErrorLogs` ile `Debug.LogError` ve assert), `AppDomain.UnhandledException` ve `TaskScheduler.UnobservedTaskException` kancalarını bağlar. Her hata `CaptureError` üzerinden geçer:

- İleti ve yığın kişisel veriden (e-posta, IP, telefon, JWT/belirteç, `password=`/`token=` değerleri, kullanıcı yolu, URL sorgusu) arındırılır.
- Yığın çerçeveleri dosya yolu, satır, adres ve bağımsız değişken olmadan normalleştirilir; hata türü ve ilk altı çerçevenin SHA-256 özetinin ilk 16 karakteri `fingerprint` olur.
- Örnekleme (`errorSampleRate`) ve hız sınırı: dakikada en çok `errorsPerMinute` (10), aynı parmak izi için dakikada 2. Sınıra takılan hata sayılır (`GetStatus().ErrorsSuppressed`); sayı tel üzerinde taşınmaz. Alan adları ve türleri `packages/schemas/utp/v1/event.schema.json` ve toplayıcı filtresiyle aynıdır; `origin` Unity istisnaları için `uncaught_exception`, elle çağrı için `manual`. Parmak izi biçimi platforma özgüdür (SHA-256 ilk 16 onaltılık karakter).

### Oturum

Otomatik `session_id` vardır. Oyun arka planda 30 dakika (`sessionTimeoutMinutes`) kalırsa dönüşte yeni oturum başlar; `Client.Reset()` oturumu da yeniler. Mobilde `OnApplicationPause`, masaüstünde odak kaybı arka plan sayılır. `SetSessionId` otomatik oturumu geçersiz kılar.

## Kalıcı çevrimdışı kuyruk

Kuyruk `Application.persistentDataPath/feralin/` altında diskte tutulur (WebGL hariç) ve oyun kapansa da gönderilene kadar korunur. Her olay **AES-256-GCM** ile şifrelenir (satır biçimi Android SDK ile aynı: `enc1:` + hex(iv ‖ şifreli metin ‖ etiket), ilişkilendirilmiş veri olay kimliği); GCM, Unity'nin Mono/IL2CPP profilinde `AesGcm` sınıfı bulunmadığı için yönetilen kodda yazılmıştır ve NIST vektörleri ile .NET `AesGcm` karşılaştırmasıyla sınanmıştır.

| Platform | Anahtar koruması (`GetStatus().QueueProtection`) | Durum |
|---|---|---|
| Android | `android_keystore`: 32 baytlık veri anahtarı, dışarı aktarılamayan Keystore AES-256-GCM anahtarıyla sarılır (`FeralinKeystore.java`) | Cihazda sınanmadı |
| iOS | `ios_keychain`: anahtar Keychain'de, `AfterFirstUnlockThisDeviceOnly` (`FeralinNative.mm`) | Cihazda sınanmadı |
| Windows | `windows_dpapi` (kullanıcı kapsamı), DPAPI sınıfı Unity profilinde bulunursa | Editor'de bulunmayabilir; yoksa `local_file` |
| macOS, Linux | `local_file`: anahtar kuyruğun yanındaki dosyada; yalnız sıradan inceleme ve dosya kopyalamaya karşı korur, aynı kullanıcı hesabına erişen anahtarı okuyabilir | Açıkça sınırlı |
| WebGL | Kalıcı kuyruk kapalı (bellek içi) | |

Anahtar alınamazsa (Keystore bozuk, Keychain okunamıyor) düz metne **düşülmez**: kuyruk bellekte kalır. Okunamayan satırlar (anahtar kaybı, bozulma) atılır. Tekrar gönderimde aynı `event_id` korunur (sunucu çift saymaz). Kuyruk üst sınırı (varsayılan 1000) ve en eski olayı atma kuralı diğer SDK'larla aynıdır; tek olay üst sınırı 256 Ki karakterdir. Karar verilmediyse disk dokunulmadan bekler (İzin bölümü).

## Atıf ve bağlantılar

- **Android Play Install Referrer:** kurulumda bir kez okunur, `app_first_open` olayına `attribution_source=play_install_referrer`, `fr_click` ve izin listesindeki `utm_*` yazılır. Play'in tıklama yokken döndürdüğü `organic` varsayılanı kanıt sayılmaz. Reklam izni yoksa referrer **okunmaz**; izin sonradan gelirse bir kez okunur ve kanıt `consent_followup` işaretli `deep_link_opened` ile taşınır. `fr_dl` ile gelen ertelenmiş derin bağlantı yolu `Client.ConsumeDeferredDeepLink()` ile bir kez teslim edilir.
- **Kurulum mağazası (Android):** `app_first_open` olayı `install_store` özelliğini taşır: uygulamayı kuran paketten türetilen kapalı listeden bir değer (`google_play`, `samsung_galaxy_store`, `huawei_appgallery`, `amazon_appstore`, `xiaomi_getapps`, `oppo_app_market`, `vivo_app_store`, `honor_app_market`, `sideload`, `unknown`, `other`). Yapılandırma ve ek Java eklentisi gerekmez (`FeralinBehaviour` kaynağı kendisi verir; `FeralinOptions.InstallStoreSource`). Kişisel veri ya da atıf kanıtı olmadığından reklam izninden bağımsız eklenir (analitik izni yine şarttır). Listede olmayan kurucunun paket adı gönderilmez (`other`); değer işletim sisteminin bildirdiğidir, mağaza tarafından doğrulanmaz. Okunamazsa alan eklenmez, ilk açılış yine üretilir. iOS, Editor ve masaüstünde alan yoktur. Sınıflayıcı ve çekirdek davranışı birim testlidir; `PackageManager` okuması (JNI) cihazda sınanmadı.
- **Huawei AppGallery kurulum yönlendiricisi (Android):** Play kanıt vermezse (hizmet yok, boş ya da organik varsayılan) AppGallery'nin içerik sağlayıcısındaki `referrer` değeri okunur (`FeralinHuaweiReferrer.java`, `FeralinOptions.HuaweiReferrerSource`); kanıt `attribution_source=huawei_install_referrer` ile gider. Yalnız reklam ölçümü izni açıkken okunur ve aynı izin listesinden (`fr_click`, `fr_dl`, `utm_*`) geçer. Android 11 ve üzerinde `Assets/Plugins/Android/AndroidManifest.xml` içine `<queries><package android:name="com.huawei.appmarket" /></queries>` elle eklenmelidir. Zincir ve ayrıştırma birim testlidir; Java köprüsü ve gerçek Huawei cihazı denenmedi, sütun sırası Huawei belgesinden alınmıştır.
- **Emülatör işareti (Android):** `android.os.Build` alanları saf C# sınıflayıcıdan (`EmulatorCheck.IsEmulator`) geçer; emülatörse `app_first_open` olayına `device_emulator: true` eklenir, değilse alan yoktur (`FeralinOptions.EmulatorSource`). `Build` alanlarının kendisi gönderilmez. Sezgiseldir: sunucuda kesin kanıt değil, işarettir. Sınıflayıcı birim testlidir; cihazda denenmedi.
- **SDK imzası:** `FeralinOptions.SigningKey = new SigningKey("sgn_...", "fsk_...")` (ya da `FeralinBehaviour` üzerindeki iki alan) verilirse yalnız `app_first_open` ve `deep_link_opened` olaylarına `fr_sig` eklenir (`v1.<kimlik>.<unix saniye>.<hex hmac-sha256>`; olay kimliğine ve `anonymous_id` değerine bağlıdır). Kimlik `sgn_` + 12-40 küçük harf/rakam, değer 16-200 karakter olmalıdır; geçersiz anahtar kurucuda `ArgumentException` verir ve mesajda anahtar değeri bulunmaz. Anahtar değeri loglanmaz, `ToString` yalnız kimliği yazar. Anahtar oyuna gömülüdür: imza sahte kurulumu zorlaştırır, imkânsız kılmaz. Sunucuyla aynı sınama vektörüyle birim testlidir; cihazda denenmedi.
- **Uygulama bağlantıları:** `Application.deepLinkActivated` (ve soğuk açılıştaki `absoluteURL`) otomatik bağlanır. Yalnız `http(s)` bağlantılar kanıt sayılır; sorgudan yalnız `fr_click`, `fr_dl`, `utm_*` okunur, ham URL saklanmaz (`page_url` yalnız şema, host ve yoldur).
- **iOS:** `FeralinBehaviour.BindInstall(cb)` AdServices token'ını (`AAAttribution.attributionToken()`) rastgele kurulum kimliğiyle `POST /v1/projects/{id}/attribution/apple-adservices/tokens` ucuna iletir ve `installId` döndürür; `apiUrl` ve `projectId` gerekir. `installId`'yi kendi sunucunuza iletin ve hesap bağını yalnız oradan, gizli API anahtarıyla `account-links` ucuyla kurun. **Apple tarafında kesin tekil atıf iddia edilmez:** sunucu bugün Apple'a sormaz, token yalnız saklanır; parmak izi yoktur. Durumlar: `received`, `skipped_no_consent`, `not_configured`, `unsupported`, `token_unavailable`, `rejected`, `temporary_failure`.

### Fera Fly kısa linkleri

Oyun `https://fera.fly/kod` ya da `https://marka.fera.fly/kod` gibi bir kısa linkle doğrudan açıldığında `HandleDeepLink` (FeralinBehaviour `Application.deepLinkActivated` ile çağırır) linki yönlendiriciden gövdesiz `GET` ve `Accept: application/vnd.feralin.link+json` ile çözümler. Derin yol, UTM ve reklam izni varsa tıklama kimliği `deep_link_opened` olayına eklenir; gidilecek yolu `Client.LastShortLink?.DeepLinkPath` verir. Kendi bağlantı akışınız varsa:

```csharp
client.HandleShortLink(url, open => SceneRouter.Open(open.Destination)); // ör. /urun/42
```

Markalı alan: `FeralinOptions.ShortLinkHosts`. Cihaz sınıfı (`ios`, `android`, `desktop`) `Application.platform` değerinden verilir; model gönderilmez. Kendi `IFeralinTransport` sınıfınızı yazdıysanız `TransportRequest.Method` değerine uyun. Analitik izni yoksa istek yapılmaz.

## Gönderim

- `FeralinBehaviour.Update` otomatik gönderimi sürer (varsayılan 2 sn veya batch dolunca). Arka plan iş parçacığı yoktur, WebGL için de aynı yol geçerlidir.
- 202 → silinir. 401/403 → kuyruk atılır, oyun etkilenmez. Diğer 4xx (429 hariç) → o batch atılır. 429, 5xx ve ağ hatası → aynı içerik ve aynı `Idempotency-Key` ile üstel geri çekilmeyle (1 sn → 30 sn) yeniden denenir; `Retry-After` en çok 5 dakikaya kadar uygulanır.
- `Flush(cb)` ve `Close(cb)` sonuçlarını geri çağrıyla bildirir, oyunu bloklamaz.

Yerel geliştirmede `http://` adres kullanacaksanız Unity'nin **Allow downloads over HTTP** ayarı gerekir; yayında `https://` kullanın.

## Desteklenmeyenler ve sınırlar

- Android ve iOS yerel köprüleri (`FeralinKeystore.java`, `FeralinNative.mm`, Install Referrer JNI proxy'si) **oyuncu derlemesiyle derlenmedi, cihazda sınanmadı**. Çekirdek mantık (şifreleme, kuyruk, atıf, sözleşmeler) `dotnet test` ile; Editor yolu PlayMode ile sınandı.
- Sunucu tarafı IAP makbuz doğrulaması bu pakette değildir (makbuz doğrulayıcıları sunucuda `BLOCKED_EXTERNAL`). iOS'ta SKAN/AdAttributionKit güncellemesi yoktur.
- Native çökme (SIGSEGV, ANR) yakalanmaz; yalnız yönetilen istisna ve Unity hata kayıtları.
- Distributed tracing ve session replay yok.
- `UnityWebRequest` yalnız ana iş parçacığında çalışır; başka iş parçacığından `Flush` ağ hatası sayılır ve olay kuyrukta kalır. `Track` her iş parçacığından çağrılabilir.
- Bağımsız oyuncu derlemesi (WebGL, iOS, Android, IL2CPP) denenmedi.

## Doğrulama

```bash
# Çekirdek: netstandard2.1 + C# 9 ile derlenir, Unity gerekmez
dotnet test "sdks/unity/Tests~/Feralin.Unity.Core.Tests"

# Temiz kurulum ve gerçek toplayıcı (yalnız test veritabanı)
DATABASE_URL='postgres://...' COLLECT_ADDR=127.0.0.1:4714 node scripts/sdk-e2e/run.mjs unity
```

Uçtan uca koşu gerçek `services/collect` ile `feralin_purchase`, oyun olayları, `fr_ad_revenue`, `fr_group`, `fr_user_properties` ve `fr_error` olaylarının alındığını, makbuz belirtecinin ve e-postanın outbox'a **sızmadığını**, çevrimdışı olayın yeniden başlatmadan sonra aynı `event_id` ile tek kez teslim edildiğini ve ilk açılışın kurulum başına bir kez sayıldığını `scripts/sdk-e2e/unity_event_check.go` ile veritabanında doğrular.

`Tests/Runtime` altındaki PlayMode testleri Unity Editor içinde `UnityWebRequest`, `FeralinBehaviour`, şifreli kalıcı kuyruk ve hata kancasını sınar; projenin `manifest.json` dosyasında `"testables": ["com.feralin.unity"]` gerekir. Uçtan uca koşuya eklemek için `FERALIN_UNITY_EDITOR=<Unity.exe yolu>` verin. Verilmezse bu adım atlanır.

`package.json` içindeki `2021.3` alt sınırı API kullanımına göre yazıldı, o sürümde koşulmadı.

## Meta Install Referrer (Android)

Facebook ya da Instagram reklamından gelen kurulumun kampanya, reklam seti ve reklam bilgisi Meta'nın kendi verisinden okunur; Facebook SDK
gerekmez. Yapılacaklar:

1. Feralin panelinde Atıf ekranındaki Meta kartına Facebook App ID'yi ve Meta uygulama panelindeki Install Referrer çözme anahtarını girin.
2. SDK yapılandırmasına Facebook App ID'yi verin (`metaAppId`; Unity'de `FeralinBehaviour` alanı ya da `FeralinOptions.MetaAppId`).
3. Android 11 ve üzerinde uygulama manifestine paket görünürlüğü ekleyin (Android SDK ve Flutter eklentisi bunu kendi manifestinden
   birleştirir; Unity'de `Assets/Plugins/Android/AndroidManifest.xml` içine elle eklenir):

```xml
<queries>
    <package android:name="com.facebook.katana" />
    <package android:name="com.instagram.android" />
    <package android:name="com.facebook.lite" />
</queries>
```

Veri yalnız reklam ölçümü izni (`consent.advertising`) açıkken okunur; içerik şifrelidir ve uygulamada açılmaz.
