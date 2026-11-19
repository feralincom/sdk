# Değişiklikler

## Yayınlanmamış

## 0.3.0 (19 Kasım 2026)

- Fera Fly kısa linkleri (Android): `Feralin.handleShortLink(url)` çekirdeğin `handleShortLink` yöntemini çağırır ve `{ destination, linkCode, hasClickId }` döner; `initialize` `shortLinkHosts` alanını çekirdeğe iletir. iOS'ta adresin kendi yolu döner. Köprü testinde `FeralinStatus` kurucusu adlandırılmış parametrelere geçirildi (çekirdekteki yeni alan derlemeyi bozuyordu). Birim testli; npm'e yayımlanmadı, gerçek cihazda denenmedi (19 Kasım 2026).
- SDK imzası: `Feralin.initialize({ ..., signingKey: { id, secret } })` anahtarı Android çekirdeğine iletir; çekirdek `app_first_open` ve `deep_link_opened` olaylarını `fr_sig` ile imzalar. Geçersiz anahtarda `initialize` `false` döner. Emülatör işareti (`device_emulator`) ve Huawei AppGallery kurulum yönlendiricisi (`attribution_source=huawei_install_referrer`) çekirdekten gelir; köprüde yalnız `signingKey` eşlemesi eklendi. Yerel AAR yeniden üretildi; npm'e yayımlanmadı, gerçek cihazda denenmedi (18 Kasım 2026).
- Kurulum mağazası (Android): `app_first_open` olayı çekirdekten gelen `install_store` özelliğini taşır (kapalı liste; reklam izninden bağımsız; paket adı gönderilmez). Köprüde kod değişikliği yoktur; alan, paketle gelen çekirdek AAR'ının `npm pack` sırasında yeniden üretilmesiyle gelir. Yayımlanmış `0.2.0` paketi alanı taşımaz (18 Kasım 2026).
- Kurulum eşleştirme kodu: `Feralin.initialize({ ..., installCode })` kodu Android çekirdeğine iletir; çekirdek izin sonrası ilk olaya `fr_install_code` olarak ekler (16 Kasım 2026).

## 0.2.0

- Oyun olayı yöntemleri (`trackLevelStart/Complete/Fail`, `trackEconomySource/Sink`, `trackRewardedAdShown/Complete`, `trackIapOfferShown/Initiated`), `trackAdRevenue` (`fr_ad_revenue`, `revenue_micros`), `captureError` ve `captureUncaughtErrors` (`fr_error`: `ErrorUtils` ve işlenmemiş Promise reddi). Android, Flutter ve Unity sözleşmesiyle aynı alan adları.

## 0.1.0

- İlk sürüm: JS yüzeyi ve Android köprüsü (`sdks/android` çekirdeği). iOS `BLOCKED_EXTERNAL`. Henüz npm'e yayınlanmadı.
