# Feralin Android SDK

Kotlin kütüphanesi: consent-first olaylar, kalıcı çevrimdışı kuyruk, Play Install Referrer, App Links ve oturum yaşam döngüsü. Olaylar UTP v1 şemasıyla `POST /v1/batch` üzerinden gider. Davranış Web SDK ile aynıdır.

## Durum

| Konu | Durum |
|---|---|
| Kod, birim testleri, `assembleRelease` | Geçiyor |
| Gerçek `services/collect` + PostgreSQL | `scripts/e2e-collect.sh` ile doğrulandı |
| Emülatör (API 36, Play Store imajı) | Kurulum, izin, gerçek HTTP, çevrimdışı kuyruk doğrulandı; yerel Maven'dan boş projeye temiz kurulum ve ClickHouse satırı `scripts/e2e-clean-install.mjs` ile |
| Gerçek Play tıklamasından gelen referrer | `BLOCKED_EXTERNAL`: Play Console ve yayınlanmış uygulama gerekir; bugüne dek sahte bağlantıyla sınandı |
| Gerçek cihaz (SDK-R07) | `BLOCKED_EXTERNAL`: fiziksel cihaz gerekir |
| Maven Central yayını | `BLOCKED_EXTERNAL`: `com.feralin` namespace doğrulaması ve imza anahtarı gerekir; yayın yapılmadı |

## Gereksinimler

`minSdk 24`. Gerekçe: `ConnectivityManager.registerDefaultNetworkCallback` API 24 ister ve Flutter 3.38 varsayılanı da budur. `compileSdk 36`, AGP 8.13.2, Kotlin 2.2.20, JDK 17 ile derlenir.

Tek çalışma zamanı bağımlılığı `com.android.installreferrer:installreferrer:2.2`. `compileOnly` değil gerçek bağımlılıktır: eksik kaldığında attribution sessizce `none` olurdu, kütüphane ise 8 KB'tır ve geçişli bağımlılığı yoktur. Play dışı dağıtımda hariç tutulabilir; bu durumda SDK düşmez, kaynak `none` olur. AndroidX kullanılmaz.

Manifest'e eklenen izinler: `INTERNET`, `ACCESS_NETWORK_STATE`, referrer kütüphanesinden `BIND_GET_INSTALL_REFERRER_SERVICE`.

## Kurulum

Maven yayını olmadığından bugün yerel modül olarak eklenir:

```kotlin
// settings.gradle.kts
include(":feralin")
project(":feralin").projectDir = file("../sdks/android/feralin")

// app/build.gradle.kts
dependencies { implementation(project(":feralin")) }
```

Yayın sonrası hedef koordinat `com.feralin:android`; bugün çalışmaz.

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        Feralin.initialize(
            this,
            FeralinConfig(
                projectKey = "pk_live_...", // yalnız x-feralin-project-key başlığında taşınır
                collectUrl = "https://collect.example.com",
                consent = kayitliKarar(),   // karar yoksa null
            ),
        )
    }
}
```

`sk_` ile başlayan gizli anahtar reddedilir ve SDK kapalı kalır. Hiçbir metot uygulamaya hata fırlatmaz.

## İzin akışı

SDK kararı saklamaz. Kararın sahibi uygulama veya CMP'sidir; her açılışta `consent` ile bildirilir.

| Durum | Davranış |
|---|---|
| `consent = null` (bekleniyor) | Olay üretilmez, gönderilmez, depodaki kuyruk silinmez. Gelen App Link temizlenmiş halde yalnız bellekte bekler |
| `Consent(analytics = false)` | Olay üretilmez, kuyruk ve depodaki anonim kimlik silinir |
| `Consent(analytics = true)` | Olaylar gider. **Attribution yok** |
| `Consent(analytics = true, advertising = false)` | Olaylar gider. **Attribution yok**, sonradan izin gelse de eski bağlantı kanıtı saklanmamıştır |
| `Consent(analytics = true, advertising = true)` | Olaylar ve attribution kanıtı gider |

```kotlin
Feralin.setConsent(Consent(analytics = true, advertising = true))
Feralin.getStatus().consent?.advertising // verilen değer; verilmediyse null
```

`advertising` varsayılan olarak `true` sayılmaz; verilmediyse olayda alan bulunmaz.

### İzin yoksa attribution yok

`fr_click`, `utm_*` ve Play Install Referrer okuma yalnız `consent.advertising == true` iken kullanılır. Aksi halde:

- Referrer hiç okunmaz.
- `app_first_open` ve `deep_link_opened` üretilir, ama `attribution_source=none` taşır; `fr_click` ve `utm_*` yoktur. Sunucu bu olaylardan tıklama eşlemez.
- Uygulama `track` ile kendi `fr_click` özelliğini verse de çıkarılır.
- İzin geri çekilirse kuyrukta bekleyen `app_first_open` ve `deep_link_opened` kaybolmaz: `fr_click` ve `utm_*` çıkarılır, `attribution_source=none` olur, izin bloğu güncellenir. Uygulama olaylarından yalnız `fr_click` çıkarılır. Yalnız kanıt taşıyan `consent_followup` olayı silinir.

İzin sonradan `true` olursa:

- İlk açılış kanıtsız gönderildiyse referrer o zaman, kurulumda bir kez okunur. Kanıt varsa `deep_link_opened` olayı `attribution_source=play_install_referrer`, `fr_click`, `consent_followup=true` ve `first_open_at` ile gider. `app_first_open` kurulum başına tek olduğu için tekrar üretilmez. Referrer organik varsayılansa olay üretilmez. Sunucu geriye bakış penceresini izin anına değil `first_open_at` değerine göre değerlendirir.
- Aynı süreçte, izin henüz bildirilmemişken açılmış App Link'in kanıtı bellekte beklemişse `deep_link_opened` `attribution_source=app_link`, `fr_click` ve `consent_followup=true` ile gider. Bu olay ikinci bir açılış değildir; sunucu `consent_followup` ile açılış toplamından ayırır. Açık `advertising=false` sonrası veya süreç bittikten sonra bağlantı kanıtı kalmaz.

## Olaylar

| Olay | Ne zaman | `attribution_source` |
|---|---|---|
| `app_first_open` | Analitik izni olan ilk çalıştırmada, kurulum başına bir kez | `play_install_referrer`, `app_link` veya `none` |
| `deep_link_opened` | Her App Link açılışında | `app_link` (izin yoksa `none`), izin sonrası takip olayında `play_install_referrer` de olabilir |

Play'in tıklama yokken döndürdüğü `utm_medium=organic` ve `(not set)` değerleri kanıt sayılmaz, kaynak `none` olur.

SDK eklenen mevcut bir uygulamada ilk çalıştırma da `app_first_open` üretir; bu olay "SDK'nın gördüğü ilk açılış" anlamındadır.

```kotlin
Feralin.track("purchase", mapOf("amount" to 10.5))
Feralin.screen("home")
Feralin.identify("kullanici_42") // PII vermeyin
Feralin.flush { result -> /* HTTP durumu */ }
Feralin.reset() // çıkış: kimlikler yenilenir, kuyruk silinir
```

### Grup, kullanıcı ve global özellikler

React Native, Unity, Unreal ve Godot SDK'larıyla aynı olay sözleşmesi; sunucuda ayrı profil deposu yoktur, olay olarak saklanır:

```kotlin
Feralin.group("acct_42", mapOf("plan" to "pro"))           // fr_group: group_id + özellikler (grup kimliği 1-128 karakter)
Feralin.setUserProperties(mapOf("tier" to "gold"))          // fr_user_properties; geçerli özellik yoksa olay üretilmez
Feralin.setGlobalProperties(mapOf("app_theme" to "dark"))   // sonraki her olaya eklenir (fr_ olayları hariç); birleştirir, null değer anahtarı siler
Feralin.clearGlobalProperties()                              // hepsini siler; reset() de siler
```

- Global özellikler yalnız bellekte tutulur ve `reset()` ile silinir. Olayın kendi özelliği önceliklidir, toplam 100 özellik sınırı aşılmaz. `fr_` önekli anahtarlar ve gelir doğrulama beyanları (`verified`, `receipt` ve benzeri) global olamaz.
- E-posta, telefon ya da ad gibi kişi verisi vermeyin.

### Kurulum kimliği ve hesap eşleştirme

Kullanıcı web'de ve uygulamada kendi isteğiyle aynı hesaba girerse iki taraf bağlanabilir (şartname §31.2 yol 5; Swift, Flutter ve React Native ile aynı sözleşme):

```kotlin
Feralin.installIdentifier { installId ->
    // installId'yi kendi sunucunuza iletin; sunucunuz gizli API anahtarıyla (attribution:link) çağırır:
    // POST /v1/projects/{id}/attribution/account-links  {"surface":"app","subject_id":installId,"account_ref":"<opak hesap kimliği>","platform":"android","consent":true}
}
```

- Kimlik yalnız reklam ölçümü izniyle (analitik + reklam) üretilir ve diske yazılır; izin yoksa `null` döner. Analitik izni geri çekilince ve `reset()` ile silinir, sonraki kimlik yenidir.
- Aynı kimlik kullanıcının kendi girdiği devam kodunda (`continuity-tokens/redeem`, `install_id`) da kullanılır. Sonuç "eşleşen ilk açılış"tır (`user_confirmed`); Play indirme sayısı ya da reklam kanıtı değildir.
- Gerçek `services/saas-api` ile uçtan uca: `DATABASE_URL=... node sdks/android/scripts/e2e-account-link.mjs`.

### App Links

Etkinliklerin `ACTION_VIEW` http(s) niyetleri otomatik yakalanır. `singleTop` etkinlikte `onNewIntent` içinde `setIntent(intent)` çağırın veya `Feralin.handleIntent(intent)` kullanın. Aynı niyet döndürmede veya geçmişten açılışta iki kez sayılmaz. Özel şemalar kanıt sayılmaz.

SDK alan doğrulamasını yapmaz. `autoVerify` ve `assetlinks.json` uygulamanındır. Bir başka uygulama açık niyetle sahte URL gönderebilir; `fr_click` istemci iddiasıdır, karar sunucudaki tıklama kaydıyla verilir.

### Ertelenmiş derin bağlantı

Uygulama kurulu değilken tıklanan linkin uygulama içi yolu (panelde **Uygulama içi yol**, API'de `deep_link_path`) Play kurulumundan sonra bir kez teslim edilir:

```kotlin
Feralin.consumeDeferredDeepLink { link ->
    if (link.status == DeferredDeepLinkStatus.DELIVERED) router.open(link.path!!)
}
```

- Yol, Play `referrer` değerinde `fr_dl` olarak taşınır. Attribution açık link ve reklam ölçümü izni gerekir; izin yoksa referrer okunmaz, sonuç `CONSENT_REQUIRED` olur.
- Geri çağrı SDK iş parçacığında gelir; referrer okuması sürüyorsa bitmesini bekler.
- Yol olay özelliğine yazılmaz, sunucuya gönderilmez. İzin reddi ve `reset()` teslim edilmemiş yolu siler.
- **Yol dışarıdan gelen veridir:** Play bağlantısını başkası da üretebilir. SDK şema, host, `..` ve kodlanmış nokta, bölü, kontrol karakteri taşıyan yolu atar; yine de kendi yönlendirme tablonuzla eşleştirin, doğrudan yetkili bir eylem çalıştırmayın.
- Birim testlidir; gerçek Play kurulumuyla sınanmadı (mağaza kaydı gerekir).

## Hata, oyun ve reklam geliri (X4)

- **Hata:** `Feralin.captureError(throwable)` yakalanan hatayı, `Feralin.captureUncaughtExceptions(sampleRate)` yakalanmamış istisnaları `fr_error` olarak bildirir (`fatal: true`). Mevcut `UncaughtExceptionHandler` korunur; çökme davranışı değişmez. Olay süreç ölmeden önce en çok 1 sn beklenerek kalıcı kuyruğa yazılır, gönderim sonraki açılışta olur. Giden alanlar: sınıf adı, temizlenmiş mesaj, normalize çerçevelerin SHA-256 özeti `fingerprint`, `top_frame`, `app_version` ve sembolleştirme için en çok 5 uygulama çerçevesinin konumu `frames` (derlenmiş sınıf adı, `$` yerine `~`; yöntem adı; satır; ham yığın ve kaynak dosya adı gitmez). Süreç başına en çok 20 olay, aynı parmak izi için 3.
- **ANR ve yerel çökme:** `Feralin.captureAnrAndNativeCrashes()` (`initialize` sonrasında) Android 11 (API 30) ve üstünde önceki açılışın sistem kaydını (`ActivityManager.getHistoricalProcessExitReasons`, `ApplicationExitInfo`) okur ve `fr_error` olarak gönderir: ANR'de `origin: anr`, tür `ApplicationNotResponding`, sabit özet (ör. `Input dispatching timed out`; sistem açıklaması gitmez) ve ANR izinden yalnız ana iş parçacığının çerçeveleri; yerel çökmede `origin: native_crash`, tür `NativeCrash`, yalnız sinyal adı (ör. `Fatal signal SIGSEGV`), çerçeve yok (tombstone okunmaz, NDK sembolleştirme yok). Olay zamanı sistemin kaydettiği çıkış zamanı, sürüm önceki açılışın sürümüdür. Özellik ilk açıldığında önceki geçmiş raporlanmaz; kayıt izin kararını bekler, ret sonrası gönderilmez; açılış başına en çok 5 kayıt, 30 günden eskisi gönderilmez. API 30 altında sistem bu kaydı tutmaz: yöntem `false` döner, ANR yakalanmaz.
- **Sembolleştirme (R8/ProGuard):** sürümün `mapping.txt` dosyasını yükleyin; panel karartılmış çerçeveyi okuma anında özgün sınıf, yöntem, satır ve gömülü (inline) çağıranlara çözer. Satır numarası için `proguard-rules.pro`: `-keepattributes SourceFile,LineNumberTable` ve `-renamesourcefileattribute SourceFile`. Yükleme `symbols:write` yetkili gizli API anahtarıyla (proje anahtarı yükleyemez), `release` = `versionName`:

```bash
curl -X POST "https://feralin.com/api/v1/projects/$FERALIN_PROJECT_ID/android-mappings?release=1.4.2" \
  -H "Authorization: Bearer $FERALIN_SYMBOLS_KEY" -H "X-Feralin-Upload: android-mapping" \
  -H "Content-Type: text/plain" --data-binary @app/build/outputs/mapping/release/mapping.txt
```

Gradle görevi olarak (uygulamanın `build.gradle.kts`; anahtar ortam değişkeninden okunur, dosyaya yazılmaz):

```kotlin
tasks.register<Exec>("uploadFeralinMapping") {
    dependsOn("minifyReleaseWithR8")
    val mapping = layout.buildDirectory.file("outputs/mapping/release/mapping.txt")
    val release = android.defaultConfig.versionName
    commandLine("curl", "--fail-with-body", "-X", "POST",
        "https://feralin.com/api/v1/projects/${System.getenv("FERALIN_PROJECT_ID")}/android-mappings?release=$release",
        "-H", "Authorization: Bearer ${System.getenv("FERALIN_SYMBOLS_KEY")}", "-H", "X-Feralin-Upload: android-mapping",
        "-H", "Content-Type: text/plain", "--data-binary", "@${mapping.get().asFile}")
}
```

Dosya en çok 48 MB, proje başına 100 dosya, varsayılan 90 gün saklanır; aynı sürümün yeniden yüklenmesi eskisini değiştirir.
- **Oyun:** `trackLevelStart/Complete/Fail`, `trackEconomySource/Sink` (sanal para birimi; gerçek gelir değildir), `trackRewardedAdShown/Complete`, `trackIapOfferShown/Initiated`. Sözleşme `packages/schemas/utp/v1/game-events.md`; sözleşme dışı girdide `null` döner ve olay üretilmez.
- **Reklam geliri:** `Feralin.trackAdRevenue(AdRevenueInput(network = "admob", adFormat = AdFormat.REWARDED, revenueMicros = 12_500, currency = "USD"))` (AdMob `OnPaidEventListener`, AppLovin MAX `onAdRevenuePaid` geri çağrısından). `fr_ad_revenue` ayrı bir gelir sınıfıdır: satın alma gelirine (`trackRevenue`) ve reklam harcamasına karışmaz; istemci beyanıdır ve sunucuda `ESTIMATED` kalır (reklam ağı mutabakatı `BLOCKED_EXTERNAL`). Tutar para biriminin milyonda biridir, tam sayıdır.
- Birim testlidir (`ErrorAndGameEventTest`, `IdentityAndExitTest`, Robolectric `AppExitReaderTest`). ANR yolu API 36 emülatöründe uçtan uca sınandı (`scripts/e2e-exit-info.mjs`: örnek uygulamanın yalnız adb kabuğunun tetikleyebildiği `AnrProbeReceiver` alıcısıyla arka planda zorla ANR, sistem kaydı `REASON_ANR`, sonraki açılışta `fr_error` gerçek toplayıcı outbox'ında, aynı R8 derlemesinin `mapping.txt` dosyasıyla gömülü çağrılar ve özgün satır çözümü); gerçek cihazda ve yerel çökmeyle sınanmadı.

## Gizlilik sınırları

- Toplanmaz: IP, reklam kimliği (GAID), Android ID, cihaz modeli, ekran, işletim sistemi sürümü. `User-Agent` yalnız SDK adı ve sürümüdür.
- Referrer dizgisinden yalnız `fr_click` ve `utm_source|medium|campaign|term|content` okunur. Bilinmeyen parametre, zaman damgası ve ham dizgi saklanmaz, loglanmaz.
- URL'de sorgu ve parça gönderilmez; `page_url` yalnız scheme, host ve path taşır.
- Kuyruk `noBackupFilesDir` altındadır: Auto Backup geri yüklemesi ilk açılış işaretini veya anonim kimliği yeni kuruluma taşımaz. Olay gövdeleri diskte Android Keystore anahtarıyla (AES-256-GCM, olay kimliği ilişkilendirilmiş veri) şifreli tutulur; anahtar dışarı aktarılamaz ve yedekle taşınmaz. Eski sürümden kalan düz metin satırlar ilk okunuşta şifrelenir, açılamayan satır atılır. Keystore kullanılamazsa düz metne düşülmez, kuyruk bellekte kalır. Kimlik ve işaret alanları (anonim kimlik, ilk açılış işareti) şifresizdir. Şifre birim testlidir; Keystore yolu gerçek cihazda sınanmadı.
- Anonim kimlik izin verilmeden diske yazılmaz.

## Gönderim ve pil

Kuyruk en fazla 1000 olay tutar, aşılınca en eskisi atılır. Tek istekte en fazla 500 olay (varsayılan 50) ve 900 KB gider. `202` ve kalıcı `4xx` kuyruktan siler; `429`, `5xx` ve ağ hatası tutar. Yeniden deneme üstel (5 sn ile 15 dk, jitter) ve `Retry-After` uyumludur; sonucu bilinmeyen batch aynı içerik ve aynı `Idempotency-Key` ile denenir. Anahtar, Web SDK ile aynı şekilde tüm `event_id`'lerin özetidir.

Kuyruk boşken zamanlayıcı yoktur. Arka plana geçişte bir kez gönderim denenir, sonra yeniden deneme ve ağ dinleyicisi durur; WorkManager kullanılmadığı için kalan olaylar sonraki açılışta gider.

Oturum: `session_id` süreç başına üretilir, 30 dakikadan uzun arka plan sonrası yenilenir.

## React Native

`sdks/react-native` bu çekirdeği kullanır. `FeralinConfig.wrapper` yalnız resmî sarmalayıcılar içindir: olayın `platform` ve `sdk` alanlarını belirler, UTP listesi dışında platform kabul etmez. Yerel kurulum için çekirdek yalnız dizine yayınlanır, uzak depo tanımlı değildir: `./gradlew :feralin:publishReleasePublicationToLocalVendorRepository -PferalinVendorRepo=<dizin>`.

## iOS

Bu paket yalnız Android'dir. iOS Swift SDK'sı yazılmadı: `BLOCKED_EXTERNAL`, macOS ve Xcode gerekir. Normal web, App Store, kurulum zinciri kesin tekil attribution vermez; kanıt yoksa sonuç `unknown` kalır.

## Geliştirme

```bash
export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"   # Windows (Git Bash); macOS: ~/Library/Android/sdk, Linux: ~/Android/Sdk
cd sdks/android
./gradlew test assembleRelease
DATABASE_URL='postgres://kullanici:parola@127.0.0.1:5432/test_db?sslmode=disable' scripts/e2e-collect.sh
```

`CollectorE2ETest` ortam değişkenleri yoksa atlanır; atlanma doğrulama sayılmaz. Betik `services/collect`'i derleyip başlatır, testleri koşar ve testin kendi `batch_id` ile `event_id` değerlerini `collect_outbox` üzerinde `scripts/outbox_check.go` ile doğrular. Veritabanı paylaşımlıysa sayaç farkına bakılmaz. Yalnız test veritabanı kullanın.

Örnek uygulama (`sample/`) emülatörden `http://10.0.2.2:4691` adresine bağlanır:

```bash
./gradlew :sample:assembleDebug
adb install -r sample/build/outputs/apk/debug/sample-debug.apk
adb shell am start -a android.intent.action.VIEW -d "'https://links.feralin.test/kampanya?fr_click=demo_click_0000001&token=gonderilmez'" com.feralin.sample
```

Anahtar deposu üretilmez ve commit edilmez; `assembleRelease` imzasız APK üretir.

### Temiz kurulum (yerel Maven)

`scripts/e2e-clean-install.mjs` SDK'yı `:feralin:publishToMavenLocal` ile yalnız koşuya özgü bir yerel Maven dizinine
(`-Dmaven.repo.local`, `~/.m2` ve registry değil) yayımlar; `sample/` kaynağını proje bağımlılığı olmadan, `com.feralin:android`
koordinatıyla tek modüllü boş bir Gradle projesine koyar, release APK'yı (R8) derler, kendi emülatöründe (port 5562) düğmelere
dokunarak izin, olay, gönderim, ağ kesikken kuyruk ve geri gönderimi yürütür; olayları gerçek toplayıcı, collect worker ve ClickHouse
üzerinde doğrular. Emülatördür, gerçek cihaz değildir; adb kurulumunda Play referrer kanıtı yoktur, kaynak `none` beklenir.

```bash
DATABASE_URL='postgres://...' CLICKHOUSE_URL=http://127.0.0.1:18127 node sdks/android/scripts/e2e-clean-install.mjs
```
