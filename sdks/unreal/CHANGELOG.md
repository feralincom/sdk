# Değişiklik günlüğü

## Yayınlanmamış

- Kurulum eşleştirme kodu: Proje Ayarları `InstallCode` ve Blueprint `SetInstallCode`. Kod ilk üretilen olaya `fr_install_code` olarak eklenir ve silinir; biçim Web/Android SDK ve toplayıcıyla aynı (`^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$`), uymayan değer yok sayılır. İzin yokken ya da özellik sınırı doluyken sonraki olayı bekler.

## 0.2.0

- Kalıcı şifreli çevrimdışı kuyruk (AES-256-GCM, Unity ve Android ile aynı `enc1:` satır biçimi; aynı `event_id` ile tekrar gönderim; sınır diske de uygulanır).
- `TrackRevenue` (`feralin_purchase`, istemci beyanı), `TrackAdRevenue` (`fr_ad_revenue`, `revenue_micros`), `Group`, `SetUserProperties`.
- Oyun olayları: seviye, ekonomi, ödüllü reklam, `iap_*` (`packages/schemas/utp/v1/game-events.md`).
- `CaptureError` ve motor günlüğü Error kayıtları: `fr_error` (kişisel veri ayıklama, çerçeve normalleştirme, parmak izi, örnekleme, hız sınırı).
- 30 dakikalık otomatik oturum; arka plana geçişte gönderim.
- `HandleDeepLink` (`deep_link_opened`), Android Play Install Referrer (`app_first_open`, ertelenmiş yol), iOS AdServices `BindInstall`.
- Android (Java, UPL, JNI) ve iOS (.mm) yerel köprüleri: derlenmedi, cihazda sınanmadı.
- `sdks/cpp` `wire.hpp`: `EventCore::restore` eklendi (kalıcı kuyruktan geri yükleme).

## 0.1.0

İlk sürüm: bellek içi kuyruk, izin kapısı, UTP v1 batch gönderimi.
