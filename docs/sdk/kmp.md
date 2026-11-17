<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Kotlin Multiplatform: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/kmp/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Kotlin |
| Paket | `com.feralin:feralin-kmp` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/kmp` |
| Registry | Maven Central: **BLOCKED_EXTERNAL** (gereken: com.feralin namespace doğrulaması ve imza anahtarı) |
| Derleme | `node scripts/sdk-dry-run/gradle.mjs sdks/android -p ../kmp jvmJar` |
| Test | `node scripts/sdk-dry-run/gradle.mjs sdks/android -p ../kmp jvmTest` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `Maven Central` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
sdks/android/gradlew -p sdks/kmp publishKotlinMultiplatformPublicationToLocalE2ERepository publishJvmPublicationToLocalE2ERepository -PferalinLocalRepo=file:///mutlak/yol/maven-repo
```

```kotlin
repositories { maven { url = uri("file:///mutlak/yol/maven-repo") }; mavenCentral() }
dependencies { implementation("com.feralin:feralin-kmp:0.1.0") }
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | PARTIAL (JVM ve Android OkHttp emülatörde gerçek toplayıcıyla sınandı; iOS derlenmedi; yayınsız) |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil; iOS derlenmedi) |
| consent | PARTIAL (istemci düzeyinde; JVM sınandı, iOS derlenmedi) |
| identity | PARTIAL (identify, group, setUserProperties, setGlobalProperties/clearGlobalProperties ortak kodda; reset yok; jvmTest ile sınandı, Android ve iOS hedefinde koşmadı, iOS derlenmedi) |
| attribution | PLANNED (platform köprüleri yok; sdks/android ve sdks/swift kullanılır) |
| deeplink | PLANNED |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; jvmTest testli, gerçek toplayıcı e2e yok) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; jvmTest testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PARTIAL | commonMain, jvmMain ve androidMain derlendi; iosMain yazıldı, derlenmedi: Kotlin/Native iOS macOS ister. |
| build | PARTIAL | jvmJar ve compileReleaseKotlinAndroid geçti (Gradle 8.14.2, Kotlin 2.2.20, Ktor 3.3.3); iOS NOT_RUN, macOS yok. |
| test | PARTIAL | jvmTest 40 test 0 kaldı, gerçek TCP ve CIO dahil; testDebugUnitTest 34 test 0 kaldı, ana makine JVM'inde sahte taşımayla. iOS testleri NOT_RUN, macOS yok. |
| registry | BLOCKED_EXTERNAL | Maven Central namespace ve imza anahtarı yok. |
| clean_install | PARTIAL | JVM ve Android: yerel Maven dizinine yayımlandı; boş Gradle projesine (JVM) ve boş Android uygulamasına (13 Kasım 2026, scripts/e2e-emulator.mjs, release APK R8 ile) kuruldu. iOS kurulumu denenmedi: macOS gerekir. |
| event_receipt | PARTIAL | JVM: scripts/sdk-e2e/run.mjs kmp: 202, outbox, izinsiz red, 401, idempotency geçti. Android OkHttp (13 Kasım 2026, scripts/e2e-emulator.mjs, API 36 emülatör, gerçek cihaz değil): 202, ağ kesikken kuyrukta tutma, ağ gelince gönderim, outbox ve ClickHouse FINAL satırları tam bir kez. iOS Darwin motoru sınanmadı. |
| documentation | PASS | docs/sdk/kmp.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
