# Feralin Kotlin Multiplatform SDK

`commonMain` içinde ortak UTP v1 istemcisi; `jvmMain`, `androidMain`, `iosMain` yalnız Ktor motorunu, saat, kilit ve rastgele kaynağını verir. HTTP Ktor client ile yapılır. Olaylar `POST /v1/batch` üzerinden gider.

## Durum

| Hedef | Derleme | Birim testi | Gerçek `services/collect` |
|---|---|---|---|
| JVM (`jvmMain`, CIO) | Geçti | `jvmTest` 46 test, 0 kaldı | `run.mjs kmp`: 202, outbox, izinsiz red, 401, idempotency geçti |
| Android (`androidMain`, OkHttp) | Geçti | `testDebugUnitTest` 34 test, 0 kaldı; ortak testler ana makine JVM'inde, sahte taşımayla | `scripts/e2e-emulator.mjs`: yerel Maven'dan boş Android projesine kurulum, release APK (R8), API 36 emülatörde 202, ağ kesikken kuyruk, geri gönderim, outbox ve ClickHouse satırı. Emülatördür; gerçek cihaz `NOT_RUN` |
| iOS (`iosMain`, Darwin) | **`NOT_RUN`: Kotlin/Native iOS macOS ister, derlenmedi** | `NOT_RUN` | `NOT_RUN` |
| Maven Central | `BLOCKED_EXTERNAL`: `com.feralin` namespace ve imza anahtarı yok; yayın yapılmadı | | |

Android SDK yoksa Android hedefi kurulmaz (`ANDROID_HOME`, `ANDROID_SDK_ROOT` ya da `local.properties`), JVM hedefi yine derlenir. Gradle iOS hedeflerini macOS dışında atlar; bu atlama derlendi demek değildir.

## Kurulum

Yayın olmadığından Maven koordinatı bugün çalışmaz (hedef `com.feralin:feralin-kmp`). Yerel Maven dizinine yayımlayıp oradan kurulur:

```bash
sdks/android/gradlew -p sdks/kmp publishKotlinMultiplatformPublicationToLocalE2ERepository publishJvmPublicationToLocalE2ERepository -PferalinLocalRepo=file:///mutlak/yol/maven-repo
```

```kotlin
repositories { maven { url = uri("file:///mutlak/yol/maven-repo") }; mavenCentral() }
dependencies { implementation("com.feralin:feralin-kmp:0.1.0") }
```

Kotlin 2.2.20, Ktor 3.3.3, JDK 17 ile derlendi, JVM hedef baytkodu 11. Android `minSdk 24`. Ktor JVM'de `slf4j-api` getirir; sağlayıcı yoksa SLF4J bir kez uyarı yazar, SDK log yazmaz.

## En kısa örnek

```kotlin
val client = FeralinClient(
    FeralinConfig(
        projectKey = "pk_live_...",
        collectUrl = "https://collect.example.com",
        consent = Consent(analytics = true),
    ),
)

client.track("order_completed", mapOf("order_id" to "ord_1", "amount" to 249.9), userId = "user_42")
val sonuc = client.flush()   // suspend; ağ hatasında fırlatmaz, sonuç sonuc.error içinde
client.close()               // suspend; kalan olayları en fazla 5 sn içinde gönderir
```

`sk_` ile başlayan gizli anahtar reddedilir. Doğrulama hatası `FeralinException.InvalidEvent` fırlatır. `track`, `identify`, `setConsent` askıya almaz; `flush` ve `close` `suspend`.

## İzin

Varsayılan izin hepsi kapalıdır. Karar uygulamanındır; `FeralinConfig.consent` ve `setConsent` ile verilir.

- `analytics` yoksa olay üretilmez, `track` `null` döner. Geri çekilince kuyruk atılır.
- `advertising` yoksa `fr_click` çıkarılır.
- 401 ve 403 kuyruğu atar, uygulama düşmez. Ağ hatası, 5xx ve 429 kuyrukta tutar, aynı `Idempotency-Key` ile 1 sn → 30 sn geri çekilmeyle yeniden dener.

Anahtar loglanmaz, `toString` ve `status` içinde yoktur. PII toplanmaz, parmak izi yok, `verified` gönderilmez. SDK iOS'ta ATT penceresi göstermez, Android'de reklam kimliği okumaz.

## Desteklenmeyenler

- Kalıcı kuyruk yok: bellek içidir, süreç ölünce kaybolur. Kalıcı kuyruk için Android'de `sdks/android`, iOS'ta henüz yok.
- Platform köprüleri yok: Play Install Referrer, AdServices, SKAdNetwork, AdAttributionKit, App Links, Universal Links. Bunlar için `sdks/android` ve `sdks/swift`.
- `reset`, `page`, `screen`, yakalanmamış hataların otomatik yakalanması, sembolleştirme konumları (`frames`) ve OTel yok. `group`, `setUserProperties`, `setGlobalProperties`, `trackRevenue` ve `captureError` vardır (aşağıda).
- Tel `platform` değeri JVM'de `java`, Android'de `android`, iOS'ta `ios`.

## Kimlik yöntemleri (UTP §8.2)

```kotlin
client.setGlobalProperties(mapOf("app_release" to "2.4.0"))           // fr_ ile başlamayan her olaya eklenir
client.setUserProperties(mapOf("plan" to "pro", "seats" to 12), userId = "user_42")   // fr_user_properties
client.group("acme-team", mapOf("plan" to "team"), userId = "user_42")                // fr_group
client.clearGlobalProperties()
```

Anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, çağrı başına en çok 50 özellik; değer dizge (≤256 karakter, e-posta biçimi değil), sonlu sayı ya da mantıksal. Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) ve `verified` gibi doğrulama alanları sessizce düşer (SDK log yazmaz; `setGlobalProperties` düşen sayıyı döner); geçerli özellik kalmazsa olay üretilmez ve `null` döner. `group_id` 1-128 karakter, `@` ve kontrol karakteri içermez; uymazsa `null` (fırlatmaz). Global özellikte `null` anahtarı siler, toplam en çok 50 anahtar, olayın kendi özelliği aynı anahtarda kazanır. `reset` olmadığından globaller `clearGlobalProperties` ile silinir. Toplayıcı yalnız projenin özellik izin listesindeki anahtarları saklar. Ortak kod `jvmTest` ile sınandı; Android ve iOS hedeflerinde koşmadı.

## Gelir (`trackRevenue`)

```kotlin
client.trackRevenue(
    Revenue(transactionId = "GPA.1234-5678", amountMinor = 4999, currency = "TRY", productId = "pro_monthly",
        purchaseType = PurchaseType.SUBSCRIPTION_START, receipt = Receipt(ReceiptProvider.GOOGLE, purchaseToken)),
    userId = "user_42",
)   // feralin_purchase
```

Tutar küçük birimde tam sayıdır (49,99 TL = 4999), `quantity` ile çarpılmaz; para birimi ISO 4217 üç büyük harf. Kurallar Web SDK `buildRevenueProperties` ile aynıdır: `transactionId` 1-128, `amountMinor` 0..2^53-1, `productId` verilirse 1-128, `quantity` 0-100000, abonelik iptalinde tutar 0, makbuz belirteci 1-8192. Uymayan girdide olay üretilmez ve `null` döner. İstemci beyanıdır: `verified`, `verification`, `receipt_digest` gibi alanlar özelliklerden düşer; satır yalnız sunucudaki makbuz doğrulayıcısı onaylarsa REAL_VERIFIED, aksi hâlde ESTIMATED sayılır.

## Hata bildirimi (`captureError`)

```kotlin
val client = FeralinClient(FeralinConfig(projectKey, collectUrl, consent, appVersion = "2.4.1"))
try { checkout() } catch (e: Exception) { client.captureError(e) }        // fr_error, handled
// Uygulamanın kendi yakalanmamış hata işleyicisinden: client.captureError(e, uncaught = true)  → fatal, uncaught_exception
```

Gövde Android SDK ile aynı alanlardır: `error_type` (sınıf adı, ≤64), `message` (e-posta, URL, UUID, belirteç ve uzun sayı etiketlenir, ≤200), `fingerprint` (en üst beş uygulama çerçevesinin FNV-1a 64 özeti; çerçeve yoksa rakamsız mesaj), `top_frame` (`paket.Sınıf.yöntem`, ≤160), `frame_count`, `app_version` (verildiyse), `handled`, `fatal`, `origin`. Ham yığın izi, dosya adı ve satır numarası gitmez. İstemci başına en çok 20, aynı parmak izi için en çok 3 olay; `errorSampleRate` örnekler. İzin yoksa, sınır dolduysa ya da istemci kapandıysa `null` döner, hiçbir durumda fırlatmaz. Çerçeveler JVM ve Android yığın biçiminden okunur; iOS (Kotlin/Native) yığın biçimi okunmaz, orada parmak izi mesajdan türer (iOS derlenmedi).

## Geliştirme

Kendi Gradle sarmalayıcısı yoktur, `sdks/android` sarmalayıcısı kullanılır:

```bash
cd sdks/android
./gradlew -p ../kmp jvmTest
ANDROID_HOME="$LOCALAPPDATA/Android/Sdk" ./gradlew -p ../kmp testDebugUnitTest compileReleaseKotlinAndroid
./gradlew -p ../kmp iosSimulatorArm64Test   # yalnız macOS; koşmadı
cd ../..
DATABASE_URL='postgres://KULLANICI:PAROLA@127.0.0.1:5432/TEST_VERITABANI?sslmode=disable' node scripts/sdk-e2e/run.mjs kmp
# Android OkHttp motoru kendi emülatöründe (port 5562), toplayıcı → collect worker → ClickHouse
DATABASE_URL='postgres://...' CLICKHOUSE_URL=http://127.0.0.1:18127 node sdks/kmp/scripts/e2e-emulator.mjs
```
