# Değişiklik günlüğü

## Yayınlanmamış

## 0.3.0 (19 Kasım 2026)

- Fera Fly kısa linkleri: `HandleDeepLink` kısa linki (`FeralinOptions.ShortLinkHosts`, varsayılan `fera.fly` ve alt alanları) yönlendiriciden gövdesiz `GET` ile çözümler; derin yol, UTM ve (reklam izniyle) tıklama kimliği `deep_link_opened` olayına eklenir. Yeni: `HandleShortLink(url, onResult)` → `ShortLinkOpen`, `LastShortLink`, `ShortLinks` yardımcıları, `TransportRequest.Method`, `FeralinOptions.ShortLinkDevice`; `UnityWebRequestTransport` GET isteğini gövdesiz gönderir. Birim testli (çekirdek); Unity oynatıcısında ve gerçek cihazda denenmedi (19 Kasım 2026).
- SDK imzası: `FeralinOptions.SigningKey` (ve `FeralinBehaviour` alanları) verilirse yalnız `app_first_open` ve `deep_link_opened` olayları `fr_sig` ile imzalanır (`v1.<kimlik>.<unix saniye>.<hex hmac-sha256>`; Android SDK ve sunucuyla aynı dizgi ve sınama vektörü). Geçersiz anahtar yapılandırma hatasıdır; değer loglara düşmez. Birim testlidir, cihazda denenmedi (18 Kasım 2026).
- Emülatör işareti (Android): `EmulatorCheck` ve `FeralinOptions.EmulatorSource`; emülatörde `app_first_open` olayına `device_emulator: true` eklenir, değilse alan yoktur, okuma hatası ilk açılışı durdurmaz. Sınıflayıcı birim testlidir, cihazda denenmedi.
- Huawei AppGallery kurulum yönlendiricisi (Android): `FeralinHuaweiReferrer.java`, `FeralinOptions.HuaweiReferrerSource`; Play kanıt vermezse ve reklam ölçümü izni açıksa okunur, `attribution_source=huawei_install_referrer` ile gider. Manifestte `com.huawei.appmarket` için `<queries>` gerekir (README). Zincir birim testlidir; Java köprüsü ve Huawei cihazı denenmedi.
- Kurulum mağazası (Android): `app_first_open` olayına `install_store` eklenir; uygulamayı kuran paketten türetilen kapalı liste (`InstallStore`, `FeralinOptions.InstallStoreSource`, `UnityAttribution.CreateInstallStoreSource()`). Reklam izninden bağımsızdır, listede olmayan kurucunun paket adı gönderilmez, okuma hatası ilk açılışı durdurmaz. JNI okuması cihazda sınanmadı (18 Kasım 2026).
- UPM Git adresi: `https://github.com/feralincom/sdk.git?path=sdks/unity#sdks/unity/v0.2.0`; `package.json` içine `documentationUrl`, `changelogUrl`, `licensesUrl` eklendi. Etiket henüz gönderilmedi (17 Kasım 2026).
- Kurulum eşleştirme kodu: `FeralinOptions.InstallCode` izin sonrası kuyruğa giren ilk olaya `fr_install_code` olarak eklenir; olay kuyruğa girmezse kod sonrakine kalır (16 Kasım 2026).

## 0.2.0 (yayınlanmadı)

- Kalıcı, şifreli çevrimdışı kuyruk: `Application.persistentDataPath`, AES-256-GCM (yönetilen, Android SDK ile aynı satır biçimi), anahtar Android Keystore (`FeralinKeystore.java`), iOS Keychain (`FeralinNative.mm`), Windows DPAPI ya da açıkça `local_file`. Tekrar gönderimde aynı `event_id`, sınır ve eski olayı atma kuralı diğer SDK'larla aynı. İzin kararı yokken disk dokunulmaz.
- Gelir sözleşmesi: `TrackRevenue` → `feralin_purchase` (Android, Flutter, React Native ile aynı kurallar). `TrackIapPurchase` artık `iap_purchase` değil `feralin_purchase` üretir ve `transactionId` ister (**davranış değişikliği**; paket yayınlanmadığı için geçiş yolu yok).
- `Group` (`fr_group`), `SetUserProperties` (`fr_user_properties`), 30 dakikalık otomatik oturum.
- Atıf: Android Play Install Referrer (`app_first_open`, `consent_followup`), uygulama bağlantısı (`deep_link_opened`), ertelenmiş derin bağlantı yolu, iOS AdServices token'ı ve kurulum kimliği (`BindInstall`), iOS ATT kısıtı.
- Oyun olayları: `level_fail`, `economy_source`, `economy_sink`, `rewarded_ad_shown`, `rewarded_ad_complete`; reklam geliri `fr_ad_revenue`.
- Hata yakalama `fr_error`: Unity günlük kancası, yakalanmamış istisna, PII temizliği, normalleştirilmiş çerçeve parmak izi, örnekleme ve hız sınırı.
- Android ve iOS yerel köprüleri derlenmedi ve cihazda sınanmadı.

## 0.1.0 (yayınlanmadı)

- Motor bağımsız çekirdek: `Track`, `Identify`, `SetConsent`, `Flush`, `Tick`, `Close`, sınırlı bellek kuyruğu, deterministik `Idempotency-Key`, üstel geri çekilme.
- `UnityWebRequestTransport` ve `FeralinBehaviour` (yaşam döngüsü, rastgele anonim kimlik).
- Oyun olayları: `level_start`, `level_complete`, `iap_purchase` (istemci beyanı).
