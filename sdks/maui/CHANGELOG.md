# Değişiklik günlüğü

## Yayınlanmamış

- `Feralin.Sdk` çekirdeğindeki `Group`, `SetUserProperties`, `TrackRevenue` ve yeni `CaptureError` (`fr_error`) DI ile alınan `FeralinClient` üzerinden belgelendi ve testlendi (16 Kasım 2026).
- `FeralinOptions.InstallCode`: kurulum eşleştirme kodu ilk olaya `fr_install_code` olarak bir kez eklenir; `AppVersion` verilmezse platformun `AppInfo.VersionString` değeri `fr_error` için kullanılır (16 Kasım 2026).

## 0.1.0 (yayınlanmadı)

- `MauiAppBuilder.UseFeralin`: tekil `FeralinClient`, `ILogger` bağlantısı, açılışta yapılandırma denetimi.
- Android, iOS, Mac Catalyst ve Windows yaşam döngüsünde kuyruk gönderimi; `net9.0-android` dışındaki hedefler henüz derlenmedi.
