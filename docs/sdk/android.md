<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Kotlin / Android: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/android/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Kotlin |
| Paket | `com.feralin:android` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | REGISTRY_VERIFIED |
| Kaynak dizin | `sdks/android` |
| Registry | Maven Central: **PUBLISHED** (sonraki adım: com.feralin namespace doğrulaması ve imza anahtarı) |
| Derleme | `node scripts/sdk-dry-run/gradle.mjs sdks/android assembleRelease` |
| Test | `node scripts/sdk-dry-run/gradle.mjs sdks/android test` |

## Kurulum

```kotlin
// settings.gradle.kts
include(":feralin")
project(":feralin").projectDir = file("../sdks/android/feralin")

// app/build.gradle.kts
dependencies { implementation(project(":feralin")) }
```

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

## İlk kullanım

```kotlin
Feralin.track("purchase", mapOf("amount" to 10.5))
Feralin.screen("home")
Feralin.identify("kullanici_42") // PII vermeyin
Feralin.flush { result -> /* HTTP durumu */ }
Feralin.reset() // çıkış: kimlikler yenilenir, kuyruk silinir
```

```kotlin
Feralin.group("acct_42", mapOf("plan" to "pro"))           // fr_group: group_id + özellikler (grup kimliği 1-128 karakter)
Feralin.setUserProperties(mapOf("tier" to "gold"))          // fr_user_properties; geçerli özellik yoksa olay üretilmez
Feralin.setGlobalProperties(mapOf("app_theme" to "dark"))   // sonraki her olaya eklenir (fr_ olayları hariç); birleştirir, null değer anahtarı siler
Feralin.clearGlobalProperties()                              // hepsini siler; reset() de siler
```

```kotlin
Feralin.installIdentifier { installId ->
    // installId'yi kendi sunucunuza iletin; sunucunuz gizli API anahtarıyla (attribution:link) çağırır:
    // POST /v1/projects/{id}/attribution/account-links  {"surface":"app","subject_id":installId,"account_ref":"<opak hesap kimliği>","platform":"android","consent":true}
}
```

```kotlin
Feralin.consumeDeferredDeepLink { link ->
    if (link.status == DeferredDeepLinkStatus.DELIVERED) router.open(link.path!!)
}
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız; oyun olayı yöntemleri trackLevelStart/Complete/Fail, trackEconomySource/Sink, trackRewardedAdShown/Complete, trackIapOfferShown/Initiated birim testli) |
| batch | PARTIAL (kalıcı SQLite kuyruk; olay gövdeleri Android Keystore AES-256-GCM ile şifreli ve birim testli, Keystore yolu gerçek cihazda sınanmadı; kimlik ve işaret alanları şifresiz) |
| consent | SUPPORTED (yayınsız) |
| identity | SUPPORTED (yayınsız; identify, reset; installIdentifier (ADR-0007, şartname §31.2 yol 5-6; yalnız reklam ölçümü izniyle, analitik reddi ve reset siler) gerçek services/saas-api account-links ile uçtan uca sınandı (scripts/e2e-account-link.mjs: aynı hesap user_confirmed, izin geri çekilince yeni kimlik bağlanmaz); group → fr_group, setUserProperties → fr_user_properties, setGlobalProperties/clearGlobalProperties (yalnız bellekte, birleştirir, olayın kendi özelliği önce, fr_ olaylarına eklenmez, reset siler); öteki SDK'larla aynı kural (ProfileRules: kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer istemcide düşer); toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar; JVM birim testli) |
| attribution | PARTIAL (Play Install Referrer yazıldı, gerçek Play tıklamasıyla sınanmadı) |
| deeplink | PARTIAL (App Links yakalanır, alan doğrulaması uygulamanın; ertelenmiş yol teslimi birim testli, gerçek Play kurulumuyla sınanmadı) |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; trackAdRevenue → fr_ad_revenue (ayrı gelir sınıfı: satın alma gelirine ve reklam harcamasına karışmaz; istemci beyanı, sunucuda ESTIMATED, reklam ağı mutabakatı BLOCKED_EXTERNAL)) |
| error | PARTIAL (captureError ve captureUncaughtExceptions → fr_error, yığın çerçeve parmak izi ve en çok 5 uygulama çerçevesinin konumu, örnekleme ve sınır, birim testli; captureAnrAndNativeCrashes: API 30+ ApplicationExitInfo, sonraki açılışta ANR (origin anr, ana iş parçacığı çerçeveleri, sabit özet) ve yerel çökme (origin native_crash, yalnız sinyal adı, çerçeve yok); API 36 emülatöründe zorla ANR → collect outbox fr_error → aynı derlemenin R8 mapping.txt dosyasıyla gömülü çağrı ve satır çözümü uçtan uca sınandı (scripts/e2e-exit-info.mjs); API 30 altında ANR yok; yerel çökme ve gerçek cihaz sınanmadı; R8/ProGuard eşleme yükleme ve okuma anında çözüm (0136) gerçek PostgreSQL ve ClickHouse ile entegrasyon testli; NDK sembolleştirme ve tombstone yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS |  |
| registry | PASS | Maven Central'da yayımlandı: com.feralin:android:0.1.0 (19 Kasım 2026, git bef6b14e, Central Portal dağıtımı cad38014; imza GPG BA912389B7C92BA9A702E74265D5A3DAF29F897F, keyserver.ubuntu.com ve keys.openpgp.org; ad alanı com.feralin feralin.com DNS TXT ile doğrulandı). Geri okuma: repo1.maven.org android-0.1.0.aar sha256 yerel paketle aynı. |
| clean_install | PASS | Yerel Maven deposundan React Native uygulamasına kurulum olarak sınandı. 13 Kasım 2026: scripts/e2e-clean-install.mjs: :feralin:publishToMavenLocal (koşuya özgü maven.repo.local, registry değil) → sample/ kaynağıyla tek modüllü boş Android projesi, bağımlılık com.feralin:android koordinatı → release APK (R8) → emülatörde olay ve ClickHouse satırı. Maven Central yayını ayrı halka (BLOCKED_EXTERNAL). |
| event_receipt | PASS | scripts/e2e-collect.sh ve API 36 emülatör. 13 Kasım 2026: scripts/e2e-clean-install.mjs dokunmayla izin, olay, gönderim (202), ağ kesikken kuyruk, ağ gelince gönderim; collect worker ve ClickHouse FINAL: app_first_open 1 (adb kurulumu, attribution_source none), sample_button_clicked 2. Emülatördür, gerçek cihaz değil: SDK-R07 BLOCKED_EXTERNAL. |
| documentation | PASS | docs/sdk/android.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
