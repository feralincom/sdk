# Değişiklik günlüğü

Maven Central'a yayınlanmadı: `com.feralin` namespace doğrulaması ve imza anahtarı yok (`BLOCKED_EXTERNAL`). Sürüm numarası ilk günden `0.1.0`'dır; aşağıdaki bütün değişiklikler yayınlanmamış `0.1.0` içinde birikti. Doğrulama durumu `sdks/capabilities.yaml` içindedir. Kuyruk biçimi geçişi ve geri dönüş: `docs/sdk/upgrade-guide.md`.

## 0.1.0 (yayınlanmadı)

- Kurulum eşleştirme kodu: `FeralinConfig(installCode = ...)` panelin "Kurulumu doğrula" ekranında üretilen tek kullanımlık kodu süreçte kuyruğa giren ilk olaya `fr_install_code` olarak ekler; sunucu kodu olay verisinden söker ve kurulumu projeye bağlar. Biçimi bozuk kod yok sayılır, izin yokken kod harcanmaz (14 Kasım 2026).
- İlk sürüm: consent-first olaylar, kalıcı SQLite kuyruğu, batch gönderimi, üstel geri çekilme, oturum yaşam döngüsü, Play Install Referrer ve App Links ile reklam izni kapılı atıf, örnek uygulama ve gerçek toplayıcı e2e betiği (3 Kasım 2026).
- Atıf doğruluğu ve gizlilik: izin geri çekilince kuyruktaki olaylar silinmez, yalnız `fr_click` ve `utm_*` kanıtı çıkarılır (yalnız kanıt taşıyan `consent_followup` olayı silinir); izin sonradan gelirse kanıt `first_open_at` ile `consent_followup` olayında taşınır (3 Kasım 2026).
- Yalnız yerel dizine Maven yayını (React Native paketi çekirdeği buradan alır; uzak depo ve kimlik bilgisi tanımsız) ve olay alanı düzeltmeleri (4 Kasım 2026).
- Ertelenmiş derin bağlantı yolu teslimi: `consumeDeferredDeepLink` (6 Kasım 2026).
- `trackRevenue` → `feralin_purchase` istemci beyanı; doğrulanmış gelir yalnız sunucuda (10 Kasım 2026).
- Kuyruk şifreleme: olay gövdeleri Android Keystore anahtarıyla AES-256-GCM (`enc1:` satır biçimi, olay kimliği ilişkilendirilmiş veri). Önceki yapıların düz metin satırları ilk okumada şifreli yazılır; açılamayan satır atılır. Kimlik ve işaret alanları şifresizdir (11 Kasım 2026).
- Hata, oyun ve reklam geliri: `captureError` ve `captureUncaughtExceptions` → `fr_error`; `trackLevelStart/Complete/Fail`, `trackEconomySource/Sink`, `trackRewardedAdShown/Complete`, `trackIapOfferShown`, `trackIapInitiated`; `trackAdRevenue` → `fr_ad_revenue` (12 Kasım 2026).
- Kimlik ve özellikler: `installIdentifier` (ADR-0007; yalnız reklam ölçümü izniyle, analitik reddi ve `reset` siler), `group` → `fr_group`, `setUserProperties` → `fr_user_properties`, `setGlobalProperties` (bellekte, olayın kendi özelliği önce gelir, `reset` siler) (13 Kasım 2026).
- ANR ve yerel çökme: `captureAnrAndNativeCrashes()` API 30+ `ApplicationExitInfo` kaydını sonraki açılışta `fr_error` (`origin: anr` / `native_crash`) olarak gönderir; `fr_error` artık sembolleştirme için en çok 5 uygulama çerçevesinin konumunu (`frames`: sınıf, yöntem, satır) taşır; R8/ProGuard `mapping.txt` panelde ya da `POST /v1/projects/{id}/android-mappings` ile yüklenir (13 Kasım 2026).
