# Değişiklik günlüğü

Maven Central'a yayınlanmadı: `com.feralin` namespace doğrulaması ve imza anahtarı yok (`BLOCKED_EXTERNAL`). Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## Yayınlanmamış

- `Feralin`: `trackRevenue(Revenue)` → `feralin_purchase`, `group` → `fr_group`, `setUserProperties` → `fr_user_properties`, `captureError` → `fr_error` (Android SDK ile aynı gövde, ham yığın izi yok, 60 sn'de 20 olay, parmak izi başına 3); `FeralinClient.Builder.appVersion` ve `errorSampleRate`. İstek görünümü (`scoped`) aynı yöntemleri sunar. JUnit ile sınandı (16 Kasım 2026).

## 0.1.0 (yayınlanmadı)

- `com.feralin:java`: sunucu tarafı UTP v1 istemcisi, Java 11 API'siyle derlenir (`--release 11`), çalışma zamanı bağımlılığı yok (JDK `java.net.http`); bellek içi kuyruk, üstel geri çekilme, istemci düzeyinde izin (6 Kasım 2026).
- `com.feralin:feralin-spring-boot-starter`: Java 17, Spring Boot 3.5 ve 4.1 otomatik yapılandırması; istek başına izin görünümü, uygulama kapanırken gönderim (6 Kasım 2026).
