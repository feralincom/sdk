# Feralin Java SDK ve Spring Boot starter

Feralin toplayıcısına (`services/collect`, `POST /v1/batch`) **sunucu tarafından** olay gönderir. İki paket vardır:

| Paket | Taban | Bağımlılık |
|---|---|---|
| `com.feralin:java` | Java 11 API'siyle derlenir (`--release 11`) | Çalışma zamanı bağımlılığı yok; yalnız JDK `java.net.http` |
| `com.feralin:feralin-spring-boot-starter` | Java 17, Spring Boot 3.5 ve 4.1 | `com.feralin:java`, `spring-boot-autoconfigure` |

## Durum

- Maven Central'a **yayımlanmadı** (`BLOCKED_EXTERNAL`): `com.feralin` alan adı doğrulaması ve imza anahtarı gerekir. Bugün paket adlarıyla kurulum çalışmaz.
- Temiz kurulum yerel Maven deposundan sınanır: `scripts/sdk-e2e/run.mjs java`.
- Testler JDK 17 üzerinde koşar. Java 11 uyumu derleyici düzeyindedir; gerçek bir JDK 11 çalışma zamanında koşulmadı.

## Kurulum

Yayın öncesi yerel depoya üretin:

```bash
cd sdks/java
./gradlew publishAllPublicationsToLocalVendorRepository -PferalinVendorRepo=/yerel/maven-repo
```

Windows'ta `gradlew.bat` kullanın. Tüketici proje, bu dizini Maven deposu olarak ekler ve bağımlılığı alır:

```kotlin
implementation("com.feralin:java:0.1.0")
// Spring Boot için bunun yerine:
implementation("com.feralin:feralin-spring-boot-starter:0.1.0")
```

## En kısa örnek

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

`track` ağ çağrısı yapmaz; arka plan iş parçacığı 2 saniyede bir gönderir. Süreç biterken `close()` çağrılmazsa kuyruktaki olaylar kaybolur.

## Spring Boot

```properties
feralin.project-key=${FERALIN_PROJECT_KEY}
feralin.collect-url=https://collect.example.com
```

İki değer de verilince otomatik yapılandırma devreye girer. Kuyruk ve gönderici tektir, izin ve kimlik her isteğe aittir:

```java
@RestController
class OrderController {
    private final Feralin feralin;   // istek kapsamlı vekil

    OrderController(Feralin feralin) {
        this.feralin = feralin;
    }

    @PostMapping("/orders")
    void create() {
        feralin.identify("user_42");
        feralin.track("order_completed", Map.of("order_id", "ord_1"));
    }
}

@Bean
FeralinConsentResolver consentResolver() {
    // Kendi izin kaydınızdan okuyun. Bean tanımlanmazsa feralin.consent.* geçerlidir, varsayılanı izin yok.
    return request -> Consent.analyticsOnly();
}
```

| Özellik | Varsayılan |
|---|---|
| `feralin.flush-interval` | `2s`; `0` arka plan göndericiyi kapatır |
| `feralin.batch-size` | `100`, en fazla `500` |
| `feralin.queue-limit` | `1000`; aşılınca en eski olay atılır |
| `feralin.timeout` | `10s` |
| `feralin.consent.{analytics,advertising,personalization,session-replay}` | `false` |

- Uygulama kapanırken kalan olaylar en fazla 5 saniye içinde gönderilir.
- İstek dışında (zamanlanmış iş, `@Async`, kuyruk tüketicisi) `Feralin` vekili Spring hatası verir. Orada `FeralinClient` enjekte edin ve `client.scoped(consent)` ile görünüm alın.
- Oturumdaki kullanıcı adı otomatik `user_id` yapılmaz: çoğu uygulamada e-postadır, `identify` değerini siz verirsiniz.
- Özel ağ yığını için `Transport` bean'i tanımlayın.

## İzin

- Varsayılan hiçbir izin yoktur. `analytics` kapalıyken `track` boş `Optional` döner, olay üretilmez, hata fırlatmaz.
- `fr_click` yalnız `advertising` açıksa gönderilir, aksi hâlde olaydan çıkarılır.
- `client.setConsent` analytics'i kapatırsa **bütün** kuyruk temizlenir. İstek başına görünümde (`Feralin` bean, `client.scoped`) yalnız o görünümün olayları atılır, başka kullanıcının olayına dokunulmaz.
- İstek sürerken izin geri çekilirse olay yeniden denenmez.

## Sözleşme

- Tel biçimi `packages/schemas/utp/v1/event.schema.json` ile birebir: `platform="java"`, `schema_version=1`, `sdk={name:"feralin-java",version:"0.1.0"}`, `occurred_at` UTC RFC3339 milisaniyeli, `event_id` monotonik ULID.
- `tenant_id`, `project_id`, `verified` gönderilmez; sunucu `X-Feralin-Project-Key` bağlamından çözer.
- `Idempotency-Key` diğer SDK'larla aynıdır: sıralı bütün `event_id` değerlerinin FNV-1a 64 özeti ve olay sayısı. Sonucu bilinmeyen batch aynı içerik ve aynı anahtarla yeniden denenir, araya giren olaylar sonraki batch'e kalır.
- Geri çekilme üsteldir, 1 saniyeden 30 saniyeye kadar; `Retry-After` verilmişse en az o kadar beklenir. Açık `flush()` geri çekilmeyi beklemez.
- Yalnız `pk_` anahtarı kabul edilir, `sk_` reddedilir. Anahtar loglara, hata iletilerine ve `status()` çıktısına yazılmaz.
- Loglar `System.Logger` üzerinden `feralin` adıyla gider. Parmak izi yok; IP, cihaz veya tarayıcı bilgisi toplanmaz. `user_id` ve `properties` içine PII koymamak uygulamanın sorumluluğudur.

## Gelir, kimlik ve hata

```java
client.trackRevenue(Revenue.builder("ord_1", 4999, "TRY").productId("pro_monthly").build());
client.group("acme-team", Map.of("plan", "team"));
client.setUserProperties(Map.of("plan", "pro"));
try {
    odemeAl();
} catch (RuntimeException exc) {
    client.captureError(exc);
}
```

- `trackRevenue` → `feralin_purchase`: tutar küçük birimde tam sayı, ISO 4217; kurallar diğer SDK'larla aynıdır, geçersiz girdide `Revenue.Builder.build()` `InvalidEventException` fırlatır. `verified` hiçbir zaman gönderilmez. SDK sözleşmesinde iade olayı yoktur.
- `group` → `fr_group`, `setUserProperties` → `fr_user_properties`: kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer istemcide düşer; geçersiz `group_id` ya da boş özellik kümesi boş `Optional` döner.
- `captureError` → `fr_error` (Android SDK ile aynı gövde): hata sınıfı adı, temizlenmiş en çok 200 karakterlik mesaj, ilk beş uygulama çerçevesinin parmak izi, üst çerçeve ve en çok 5 konum (sınıf, yöntem, satır). Ham yığın izi gitmez; 60 saniyede en çok 20 olay, aynı parmak izi için en çok 3. Kurucu: `appVersion`, `errorSampleRate`. Hiçbir durumda fırlatmaz.

## Desteklenmeyenler

- Kalıcı kuyruk: kuyruk bellek içidir, süreç ölürse kaybolur.
- `reset`, `setGlobalProperties`, `page`, `screen`, `optOut`, imzalı server event, yakalanmamış istisna kancası, OTel tracing.
- WebFlux için istek kapsamlı bean: reaktif uygulamada yalnız `FeralinClient` oluşur, `client.scoped(consent)` elle çağrılır. Bu yol uçtan uca sınanmadı.
- Android: mobil uygulamalar için `sdks/android` kullanın.

## Geliştirme

```bash
node scripts/sdk-dry-run/gradle.mjs sdks/java test
DATABASE_URL='postgres://...' COLLECT_ADDR=127.0.0.1:4711 node scripts/sdk-e2e/run.mjs java
```

Yayın görevi yalnız yerel dizine yazar; uzak depo ve kimlik bilgisi tanımlı değildir.
