# Unity SDK kurulum belgesi / Unity SDK setup (`com.feralin.unity` 0.2.0)

Türkçe: aşağıda. English: [below](#english).

> **Dürüst durum.** Paket registry'de yayınlanmadı (UPM kanalı `BLOCKED_EXTERNAL`). Çekirdek mantık `dotnet test` ve Unity 6000.0.84f1 Editor PlayMode ile sınandı. Android (Keystore, Install Referrer) ve iOS (Keychain, AdServices, ATT) yerel köprüleri yazıldı ama **oyuncu derlemesi ve cihaz olmadığı için derlenmedi ve cihazda sınanmadı**. Veri sınıfları: oyun gelir beyanı `ESTIMATED`, makbuz doğrulayıcı onaylarsa `REAL_VERIFIED`; iOS atfı kesin tekil değildir ve izin vermeyen kullanıcı `UNKNOWN` kalır.

## Türkçe

### 1. Kurulum

1. `sdks/unity` içinde `npm pack`; çıkan `com.feralin.unity-0.2.0.tgz` dosyasını Package Manager → **Add package from tarball** ile ekleyin (registry açılınca `manifest.json` ile).
2. Proje anahtarı public `pk_` olmalıdır; `sk_` SDK'da reddedilir.
3. Android: Play Install Referrer için `com.android.installreferrer:installreferrer:2.2` gerekir. External Dependency Manager kuruluysa paketteki `Editor/FeralinDependencies.xml` ekler; değilse `mainTemplate.gradle` içine `implementation 'com.android.installreferrer:installreferrer:2.2'` yazın. Keystore köprüsü (`Runtime/Plugins/Android/FeralinKeystore.java`) Unity'nin Gradle derlemesine otomatik girer.
4. iOS: `Runtime/Plugins/iOS/FeralinNative.mm` otomatik girer. AdServices ve ATT çerçeveleri çalışma zamanında yüklenir (Xcode'da bağlama gerekmez); Keychain için `Security.framework` Unity iOS şablonunda bağlıdır, bağlı değilse Xcode'da ekleyin. Evrensel bağlantılar için Associated Domains oyunun kendi işidir.

### 2. Başlatma ve izin

```csharp
var feralin = FeralinBehaviour.Initialize("pk_live_...", "https://collect.ornek.com",
    attributionApiUrl: "https://api.ornek.com", projectId: "proj_...");
// İzin ekranından sonra; karar verilmeden olay üretilmez ve diskteki kuyruk dokunulmaz.
feralin.SetConsent(new Consent(analytics: true, advertising: userAcceptedAds));
```

Bileşeni sahneye eklerseniz aynı ayarlar Inspector'dadır: kalıcı kuyruk, oturum süresi, otomatik atıf, hata yakalama, hata örnekleme ve hız sınırı.

### 3. Olaylar

```csharp
var c = feralin.Client;
c.TrackRevenue(new RevenueInput { TransactionId = id, AmountMinor = 4999, Currency = "TRY", ProductId = "gem_pack",
                                  Receipt = new Receipt(ReceiptProvider.Google, purchaseToken) });
c.TrackAdRevenue(new AdRevenueInput { Network = "admob", AdUnit = unit, AdFormat = AdFormat.Rewarded, RevenueMicros = 12500, Currency = "USD" });
c.TrackLevelStart("k1"); c.TrackLevelFail("k1", failReason: "zaman_doldu"); c.TrackEconomySource("gem", 50, reason: "quest_reward");
c.TrackRewardedAdShown("revive", "applovin_max"); c.TrackRewardedAdComplete("revive", "applovin_max", 1, "life");
c.Group("klan_7"); c.SetUserProperties(new Dictionary<string, object> { ["plan"] = "pro" });
```

- `feralin_purchase`: tutar küçük birimde tam sayı, ISO 4217, işlem kimliği zorunlu; `verified` ve makbuz türevi anahtarlar düşer; sözleşme dışı girdi `null` döner. Makbuz doğrulaması sunucudadır: belirteci kendi sunucunuzdan `POST /v1/projects/:id/finance/receipts/verify` ucuna gönderin.
- `iap_purchase` yardımcısı (`TrackIapPurchase`) geriye uyumluluk için durur ama `feralin_purchase` üretir ve `transactionId` ister.
- `fr_ad_revenue` satın alma gelirinden ayrıdır, deftere `feralin_purchase` olarak girmez ve ağın tahmini gelirini taşır.
- `fr_error`: Unity istisna kayıtları ve yakalanmamış istisnalar otomatik, elle `CaptureError`. PII temizlenir, yığın normalleştirilir (`fingerprint`), dakikada 10 (aynı hata için 2) sınırı ve örnekleme vardır; bastırılan sayı `GetStatus().ErrorsSuppressed` içinde (tel üzerinde taşınmaz).
- Oturum: arka planda 30 dakika geçerse yeni `session_id`.

### 4. Kalıcı şifreli kuyruk

Olaylar `Application.persistentDataPath/feralin/events.log` içinde AES-256-GCM ile şifreli tutulur; tekrar gönderimde `event_id` değişmez. `GetStatus().QueueProtection`: `android_keystore`, `ios_keychain`, `windows_dpapi` ya da `local_file` (macOS/Linux: anahtar yanındaki dosyada, yalnız sıradan inceleme koruması). WebGL'de kalıcı kuyruk kapalıdır. Anahtar alınamazsa düz metne düşülmez, kuyruk bellekte kalır.

### 5. Atıf

- Android: Play Install Referrer kurulumda bir kez okunur (`app_first_open`, `fr_click`, `utm_*`); reklam izni yoksa okunmaz.
- Bağlantılar: `Application.deepLinkActivated` otomatik `deep_link_opened` üretir; yalnız `http(s)`, yalnız `fr_click`/`fr_dl`/`utm_*`.
- iOS: `feralin.BindInstall(sonuc => ...)` AdServices token'ını kurulum kimliğiyle gönderir; `installId`'yi kendi sunucunuza iletip hesap bağını gizli anahtarla `account-links` ucundan kurun. Kesin tekil atıf iddia edilmez; parmak izi yoktur; ATT reddi reklam kanıtını kapatır.

### 6. Doğrulama komutları

```bash
dotnet test "sdks/unity/Tests~/Feralin.Unity.Core.Tests"
DATABASE_URL='postgres://...' node scripts/sdk-e2e/run.mjs unity          # gerçek collect + outbox
FERALIN_UNITY_EDITOR='E:\Unity\Editor\6000.0.84f1\Editor\Unity.exe' DATABASE_URL='postgres://...' node scripts/sdk-e2e/run.mjs unity
```

## English

> **Honest status.** The package is not published (UPM channel is `BLOCKED_EXTERNAL`). The core logic is covered by `dotnet test` and Unity 6000.0.84f1 Editor PlayMode tests. The Android (Keystore, Install Referrer) and iOS (Keychain, AdServices, ATT) native bridges are written but **were not compiled or run on a device, because there is no player build or device in this repository**. Data classes: a game's revenue claim is `ESTIMATED`, `REAL_VERIFIED` only if a server-side receipt verifier confirms it; iOS attribution is not deterministic and users who decline stay `UNKNOWN`.

### 1. Install

1. Run `npm pack` in `sdks/unity` and add the `com.feralin.unity-0.2.0.tgz` through Package Manager → **Add package from tarball** (via `manifest.json` once a registry exists).
2. Use the public `pk_` project key; `sk_` keys are rejected.
3. Android: Play Install Referrer needs `com.android.installreferrer:installreferrer:2.2`. With External Dependency Manager installed, `Editor/FeralinDependencies.xml` adds it; otherwise add `implementation 'com.android.installreferrer:installreferrer:2.2'` to `mainTemplate.gradle`. The Keystore bridge (`Runtime/Plugins/Android/FeralinKeystore.java`) is picked up by Unity's Gradle build automatically.
4. iOS: `Runtime/Plugins/iOS/FeralinNative.mm` is picked up automatically. AdServices and ATT frameworks are loaded at runtime (no Xcode linking); Keychain needs `Security.framework`, which the Unity iOS template links (add it in Xcode if not). Universal Links need Associated Domains in your app.

### 2. Initialise and consent

```csharp
var feralin = FeralinBehaviour.Initialize("pk_live_...", "https://collect.example.com",
    attributionApiUrl: "https://api.example.com", projectId: "proj_...");
// After your consent screen. Until then no events are produced and the on-disk queue is left untouched.
feralin.SetConsent(new Consent(analytics: true, advertising: userAcceptedAds));
```

### 3. Events

See the Turkish section for the code sample; the contract is shared with Android, Flutter and React Native.

- `feralin_purchase` (`TrackRevenue`): amount in minor units as an integer, ISO 4217 currency, transaction id required, `verified` and receipt-derived keys are dropped, out-of-contract input returns `null`. Receipt verification is server-side: send the token from your own server to `POST /v1/projects/:id/finance/receipts/verify`.
- `TrackIapPurchase` is kept for backward compatibility but now emits `feralin_purchase` and requires a `transactionId`.
- `fr_ad_revenue` is separate from purchase revenue and never enters the ledger as `feralin_purchase`.
- `fr_error`: Unity exception logs and unhandled exceptions are captured automatically (`CaptureError` manually). PII is scrubbed, stack frames are normalised into a `fingerprint`, with a per-minute cap (10 total, 2 per fingerprint) and optional sampling; the suppressed count is exposed in `GetStatus().ErrorsSuppressed` (not sent on the wire).
- Sessions: a new `session_id` after 30 minutes in the background.

### 4. Persistent encrypted queue

Events are stored encrypted (AES-256-GCM) in `Application.persistentDataPath/feralin/events.log`; the `event_id` is unchanged on re-send. `GetStatus().QueueProtection` is one of `android_keystore`, `ios_keychain`, `windows_dpapi` or `local_file` (macOS/Linux: key in a file next to the queue, protection against casual inspection only). Persistence is off on WebGL. If the key cannot be obtained the SDK never falls back to plaintext; the queue stays in memory.

### 5. Attribution

- Android: Play Install Referrer is read once at install (`app_first_open`, `fr_click`, `utm_*`); it is not read without advertising consent.
- Links: `Application.deepLinkActivated` produces `deep_link_opened`; `http(s)` only, and only `fr_click`/`fr_dl`/`utm_*` are read.
- iOS: `feralin.BindInstall(result => ...)` sends the AdServices token with a random install id; pass `installId` to your server and create the account link with the secret key via the `account-links` endpoint. No deterministic attribution is claimed, there is no fingerprinting, and an ATT denial disables advertising evidence.

### 6. Verification commands

```bash
dotnet test "sdks/unity/Tests~/Feralin.Unity.Core.Tests"
DATABASE_URL='postgres://...' node scripts/sdk-e2e/run.mjs unity
```
