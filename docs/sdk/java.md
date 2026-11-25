<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Java / Spring: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/java/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Java |
| Paket | `com.feralin:java, com.feralin:feralin-spring-boot-starter` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | REGISTRY_VERIFIED |
| Kaynak dizin | `sdks/java` |
| Registry | Maven Central: **PUBLISHED** (sonraki adım: com.feralin namespace doğrulaması ve imza anahtarı) |
| Derleme | `node scripts/sdk-dry-run/gradle.mjs sdks/java assemble` |
| Test | `node scripts/sdk-dry-run/gradle.mjs sdks/java test` |

## Kurulum

```bash
cd sdks/java
./gradlew publishAllPublicationsToLocalVendorRepository -PferalinVendorRepo=/yerel/maven-repo
```

```kotlin
implementation("com.feralin:java:0.1.0")
// Spring Boot için bunun yerine:
implementation("com.feralin:feralin-spring-boot-starter:0.1.0")
```

## İlk kullanım

```java
try (FeralinClient client = FeralinClient.builder("pk_live_...", "https://collect.example.com")
        .consent(Consent.analyticsOnly())
        .build()) {
    client.identify("user_42");
    client.track("order_completed", Map.of("order_id", "ord_1", "amount", 249.9));

    FlushResult result = client.flush();     // fırlatmaz
    if (result.error() instanceof TemporaryException) {
        // 5xx, 429 veya ağ: olaylar kuyrukta, aynı Idempotency-Key ile yeniden denenir
    } else if (result.error() instanceof RejectedException) {
        // 4xx (429 hariç), 401 ve 403 dahil: olaylar atıldı, uygulama düşmez
    }
}
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız) |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil) |
| consent | SUPPORTED (yayınsız; istemci düzeyinde ve istek başına görünüm) |
| identity | PARTIAL (identify, scoped; group → fr_group, setUserProperties → fr_user_properties JUnit testli; reset ve setGlobalProperties yok) |
| attribution | N/A |
| deeplink | N/A |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; JUnit testli, gerçek toplayıcı e2e yok) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; JUnit testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS | JDK 17 ile --release 11 (çekirdek) ve --release 17 (starter), -Werror; kaynak, javadoc ve ana jar üretilir. |
| test | PASS | JUnit: çekirdek 54, starter 16 test, JDK 17. Gerçek JDK 11 çalışma zamanında koşulmadı; makinede yok. |
| registry | PASS | Maven Central'da yayımlandı: com.feralin:java:0.1.0 ve com.feralin:feralin-spring-boot-starter:0.1.0 (19 Kasım 2026, git bef6b14e, Central Portal dağıtımları 2c409355 ve 95eb6777; imza GPG BA912389B7C92BA9A702E74265D5A3DAF29F897F). Geri okuma: repo1.maven.org iki jar sha256 yerel paketlerle aynı. |
| clean_install | PASS | Geçici yerel Maven deposuna yayımlanıp boş Gradle projelerine kuruldu; com.feralin grubu yalnız o depodan çözüldü, çekirdek 0 çalışma zamanı bağımlılığı. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs java: 202, outbox, izinsiz red, 401, idempotency; starter gerçek gömülü Tomcat ile Spring Boot 3.5.16 ve 4.1.2 üzerinde istek başına izin, izin geri çekme, kapanışta gönderim. Gelir doğrulaması F5. |
| documentation | PASS | docs/sdk/java.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
