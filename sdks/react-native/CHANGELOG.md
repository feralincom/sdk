# Değişiklikler

## Yayınlanmamış

- Kurulum eşleştirme kodu: `Feralin.initialize({ ..., installCode })` kodu Android çekirdeğine iletir; çekirdek izin sonrası ilk olaya `fr_install_code` olarak ekler (16 Kasım 2026).

## 0.2.0

- Oyun olayı yöntemleri (`trackLevelStart/Complete/Fail`, `trackEconomySource/Sink`, `trackRewardedAdShown/Complete`, `trackIapOfferShown/Initiated`), `trackAdRevenue` (`fr_ad_revenue`, `revenue_micros`), `captureError` ve `captureUncaughtErrors` (`fr_error`: `ErrorUtils` ve işlenmemiş Promise reddi). Android, Flutter ve Unity sözleşmesiyle aynı alan adları.

## 0.1.0

- İlk sürüm: JS yüzeyi ve Android köprüsü (`sdks/android` çekirdeği). iOS `BLOCKED_EXTERNAL`. Henüz npm'e yayınlanmadı.
