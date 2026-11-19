# @feralin/react-native

React Native SDK. JS yüzeyi doğrulama yapar, davranışın tamamı `sdks/android` çekirdeğindedir: kalıcı kuyruk, izin, idempotency, geri çekilme, Play Install Referrer, App Links. Olaylar `platform=react_native` ile gider.

## Durum

| Konu | Durum |
|---|---|
| JS birim testleri, Kotlin eşleme testi, köprü `assembleRelease` | Geçiyor |
| `npm pack` temiz kurulum, emülatörde gerçek olay (izin, opt-out, çevrimdışı flush) | `scripts/e2e-emulator.mjs` ile doğrulandı, React Native 0.87.1, API 36 |
| iOS | `BLOCKED_EXTERNAL`: Swift SDK yok, macOS ve Xcode gerekir. Modül iOS'ta bağlanmaz; SDK kapalı kalır, uygulama düşmez, `getStatus().unavailable` nedeni söyler |
| Gerçek cihaz (SDK-R07) | `BLOCKED_EXTERNAL`: fiziksel cihaz gerekir |
| npm yayını | npm'de yayımlandı: `@feralin/react-native@0.2.0` (17 Kasım 2026, `@feralin` organizasyonu); sürüm ve özet registry'den geri okundu |
| Maven Central yayını | `BLOCKED_EXTERNAL`: `com.feralin` namespace gerekir, yayın yapılmadı |

Maven Central yayını olmadığından Android çekirdeği npm paketi içindeki yerel Maven deposundan (`android/maven-repo`) çözülür. Depo `npm pack` sırasında üretilir.

## Kurulum

```bash
npm install @feralin/react-native
```

Autolinking Android köprüsünü bağlar. Elle bağlama gerekmez.

## Kullanım

```ts
import Feralin from "@feralin/react-native";

await Feralin.initialize({
  projectKey: "pk_live_...", // yalnız x-feralin-project-key başlığında taşınır
  collectUrl: "https://collect.example.com",
  consent: kayitliKarar, // karar yoksa vermeyin
});

Feralin.setConsent({ analytics: true, advertising: false });
const eventId = await Feralin.track("purchase", { amount: 10.5 });
await Feralin.screen("home");
Feralin.identify("kullanici_42"); // PII vermeyin
const result = await Feralin.flush(); // { sent, accepted, rejected, status, batchId }
Feralin.reset(); // çıkış
```

Hiçbir metot fırlatmaz, Promise reddedilmez. `sk_` anahtar reddedilir ve SDK kapalı kalır. İzin kuralları Android SDK ile aynıdır (`sdks/android/README.md`): karar yoksa olay üretilmez, `fr_click` ve `utm_*` yalnız `advertising === true` iken gider.

## Fera Fly kısa linkleri (Android)

App Link doğrudan açıldığında (`https://fera.fly/kod`, `https://marka.fera.fly/kod`) Android çekirdeği linki yönlendiriciden çözümler: derin yol, UTM ve reklam izni varsa tıklama kimliği `deep_link_opened` olayına eklenir. Otomatik yakalama açıkken bu kendiliğinden olur; gidilecek yolu almak için:

```ts
const open = await Feralin.handleShortLink(url); // { destination: "/urun/42", linkCode: "kampanya", hasClickId: true }
```

Markalı alan: `Feralin.initialize({ ..., shortLinkHosts: ["fera.fly", "go.marka.com"] })`. iOS yerel modülü olmadığı için iOS'ta adresin kendi yolu döner (`linkCode: null`). Analitik izni yoksa istek yapılmaz.

## Ertelenmiş derin bağlantı (yalnız Android)

```ts
const link = await Feralin.consumeDeferredDeepLink();
if (link.status === "delivered") navigate(link.path);
```

Attribution açık link (`deep_link_path`) ve reklam ölçümü izni gerekir (`consent_required`). iOS'ta sonuç `not_supported`: App Store parametreyi kuruluma taşımaz, parmak iziyle eşleştirme yasaktır. Yol olaya yazılmaz; dışarıdan gelen veridir, kendi yönlendirme tablonuzla eşleştirin. Gerçek Play kurulumuyla sınanmadı.

## Gelir, grup ve kullanıcı özellikleri

```ts
await Feralin.trackRevenue({ transactionId: "ord_1", amountMinor: 4999, currency: "TRY", purchaseType: "subscription_start" });
await Feralin.group("acme", { plan: "pro" });            // fr_group olayı, group_id ≤128
await Feralin.setUserProperties({ tier: "gold" });       // fr_user_properties olayı
```

`trackRevenue` kuralları Android ve Flutter SDK'larıyla aynıdır (`feralin_purchase`, tutar küçük birimde güvenli tam sayı, ISO 4217 para birimi, iptalde 0, `verified` ve makbuz türevi özellikler düşürülür); sözleşme dışı girdide `null` döner. `group` ve `setUserProperties` sunucuda ayrı profil deposuna yazmaz, olay olarak saklanır; PII vermeyin.

## Oyun olayları, reklam geliri ve hata (X4)

Sözleşme Android, Flutter ve Unity ile birebir aynıdır (`packages/schemas/utp/v1/event.schema.json`, `game-events.md`). Doğrulama JS'te yapılır; sözleşme dışı girdide `null` döner ve olay üretilmez. Davranış (kuyruk, izin kapısı, gönderim) Android çekirdeğindedir.

```ts
await Feralin.trackLevelStart("1-3", { attempt: 2 });
await Feralin.trackLevelComplete("1-3", { score: 900, durationMs: 41000 });
await Feralin.trackLevelFail("1-3", { failReason: "timeout" });
await Feralin.trackEconomySource("gold", 50, { reason: "quest" });   // sanal para, gerçek gelir değil
await Feralin.trackRewardedAdComplete("daily", { rewardAmount: 10, rewardCurrency: "gold" });
await Feralin.trackAdRevenue({ network: "admob", adFormat: "rewarded", revenueMicros: 12500, currency: "USD" });

Feralin.captureUncaughtErrors({ sampleRate: 1 });   // ErrorUtils + işlenmemiş Promise reddi
await Feralin.captureError(error);                  // try/catch ile yakalanan hata
```

- **Reklam geliri:** `fr_ad_revenue`, `revenue_micros` para biriminin milyonda biri ve tam sayıdır. Satın alma gelirine (`trackRevenue`) ve reklam harcamasına karışmaz; istemci beyanıdır, sunucuda ESTIMATED kalır, reklam ağı mutabakatı `BLOCKED_EXTERNAL`.
- **Hata:** `fr_error` olarak gider. Gider: hata türü adı, temizlenmiş mesaj (e-posta, URL, UUID, uzun sayı ve belirteç çıkarılır, 200 karakter), normalize çerçevelerin özeti `fingerprint` (satır, sütun ve dizin gitmez), `top_frame`, `app_version` (`FeralinConfig.appVersion`, yalnız JS tarafında). Ham yığın izi gitmez. Süreç başına en çok 20 olay, aynı parmak izi için 3. `captureUncaughtErrors` mevcut `ErrorUtils` işleyicisini korur ve çağırmaya devam eder; işlenmemiş Promise reddi yalnız yayın derlemesinde varsayılan açıktır (geliştirmede React Native'in kendi uyarısının yerine geçeceği için `promiseRejections: true` ile açılır).
- **Sınırlar:** Yerel (native) çökme ve ANR yakalanmaz; sembolleştirme yoktur (Hermes paketindeki adlar olduğu gibi gider); ölümcül JS hatasında olay, uygulama kapanmadan kuyruğa yetişmeyebilir. Birim testlidir (`test/signals.test.mjs`); emülatörde ayrıca koşulmadı.

## Kurulum kimliği bağlama (iOS, ADR-0007)

`Feralin.bindInstall()` iOS yerel modülünün AdServices token'ını gönderip kurulum kimliğini döndürmesini bekler. Bu pakette iOS modülü yoktur (macOS ve Xcode gerekir): modül yokken ve Android'de (Play Install Referrer yolu kullanılır) `{ status: "unsupported", installId: null }` döner. Kimlik gelince kendi sunucunuza iletin; sunucu gizli API anahtarıyla `account-links` ucunu çağırır.

## Kuyruk şifrelemesi

JS tarafında kuyruk yoktur. Kuyruk Android çekirdeğindedir ve olay gövdeleri Android Keystore anahtarıyla şifrelenir (`sdks/android/README.md`).

## Bilinçli eksikler

iOS, yerel çökme ve ANR yakalama, OTel. Köprü yeni mimaride birlikte çalışma katmanıyla yüklenir; TurboModule spesifikasyonu yoktur.

## Geliştirme

Paket pnpm çalışma alanı dışındadır: `react-native` eş bağımlılığı `auto-install-peers` ile kilit dosyasına 1400 satırdan fazla ekliyordu.

```bash
npm --prefix sdks/react-native run build
npm --prefix sdks/react-native test
sdks/android/gradlew -p sdks/react-native/android testDebugUnitTest assembleRelease
DATABASE_URL='postgres://kullanici:parola@127.0.0.1:5432/test_db?sslmode=disable' node sdks/react-native/scripts/e2e-emulator.mjs
```

Son komut temiz bir React Native projesi oluşturur, paketi kurar, release APK derler, kendi emülatörünü `-read-only` ve ayrı portla açar, gerçek `services/collect` ile senaryoyu koşar ve `collect_outbox` üzerinde doğrular. Çevrimdışı adımı yalnız kendi emülatörünün ağını kapatır. Başka emülatöre dokunmaz. Yalnız test veritabanı kullanın.

## Kurulum mağazası (Android)

İlk açılış olayı (`app_first_open`) `install_store` özelliğini taşır: uygulamayı cihaza kuran paketten türetilen kapalı listeden bir değer (`google_play`, `samsung_galaxy_store`, `huawei_appgallery`, `amazon_appstore`, `xiaomi_getapps`, `oppo_app_market`, `vivo_app_store`, `honor_app_market`, `sideload`, `unknown`, `other`). Köprüde ve JS tarafında kod ya da yapılandırma yoktur: ilk açılışı `sdks/android` çekirdeği üretir, alan oradan gelir. Reklam ölçümü izninden bağımsız eklenir (analitik izni yine şarttır); listede olmayan kurucunun paket adı gönderilmez (`other`); okunamazsa alan eklenmez, ilk açılış yine üretilir. Değer işletim sisteminin bildirdiğidir, mağaza tarafından doğrulanmaz.

Alan, paketle gelen çekirdek AAR'ına (`android/maven-repo`) bağlıdır: AAR `npm pack` sırasında `scripts/prepack.mjs` ile çekirdek kaynağından yeniden üretilir. npm'de yayımlanmış `0.2.0` paketindeki AAR bu özellikten önce derlendiği için alanı taşımaz; alan bir sonraki npm yayınıyla gelir.

## SDK imzası, emülatör işareti ve Huawei AppGallery (Android, 18 Kasım 2026)

- **SDK imzası:** `Feralin.initialize({ ..., signingKey: { id: 'sgn_...', secret: 'fsk_...' } })` anahtarı Android çekirdeğine iletir; çekirdek yalnız `app_first_open` ve `deep_link_opened` olaylarına `fr_sig` ekler. Kimlik `sgn_` + 12-40 küçük harf/rakam, değer 16-200 karakter olmalıdır; geçersiz anahtarda `initialize` `false` döner ve yerel katman çağrılmaz. Anahtar değeri loglanmaz. Anahtar uygulamaya gömülüdür: imza sahte kurulumu zorlaştırır, imkânsız kılmaz.
- **Emülatör işareti:** çekirdek emülatörde `app_first_open` olayına `device_emulator: true` ekler; değilse alan yoktur. Köprüde kod yoktur.
- **Huawei AppGallery kurulum yönlendiricisi:** Play kanıt vermezse ve reklam ölçümü izni açıksa çekirdek AppGallery'den okur; kanıt `attribution_source=huawei_install_referrer` ile gider. `<queries>` kaydı çekirdek AAR'ının manifestinden birleşir.

Üçü de paketle gelen çekirdek AAR'ına (`android/maven-repo`) bağlıdır; AAR `scripts/prepack.mjs` ile çekirdek kaynağından yeniden üretilir, npm'de yayımlanmış `0.2.0` paketinde yoktur. Köprü eşlemesi birim testlidir (`core.test.mjs`, `BridgeMappingTest.kt`); gerçek cihazda denenmedi.

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
