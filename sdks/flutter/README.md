# feralin_flutter

Feralin UTP v1 SDK for Flutter. Saf Dart çekirdek (kuyruk, izin, HTTP, idempotency, kalıcılık) ve Android platform kanalı (Play Install Referrer, App Links, ağ durumu). Davranış Web ve Android SDK ile aynıdır.

## Durum

| Konu | Durum |
|---|---|
| `flutter analyze`, `flutter test`, `dart pub publish --dry-run`, `flutter build apk` | Geçiyor |
| Gerçek `services/collect` + PostgreSQL | `scripts/e2e-collect.sh` ile doğrulandı |
| Android emülatör | Örnek uygulamayla gerçek kanal ve gerçek HTTP doğrulandı |
| Gerçek Play tıklamasından gelen referrer | `BLOCKED_EXTERNAL`: Play Console ve yayınlanmış uygulama gerekir |
| Gerçek cihaz (SDK-R07) | `BLOCKED_EXTERNAL` |
| `flutter build ios` | Bu makinede yapılamaz (macOS ve Xcode yok); iOS yolu hiç derlenmedi veya çalıştırılmadı |
| pub.dev yayını | `BLOCKED_EXTERNAL`: doğrulanmış yayıncı gerekir; yayın yapılmadı |

## Kurulum

pub.dev yayını olmadığından bugün yol bağımlılığıyla eklenir:

```yaml
dependencies:
  feralin_flutter:
    path: ../sdks/flutter
```

Gereksinim: Flutter 3.38, Android `minSdk 24`. Tek paket bağımlılığı `path_provider` (iOS depo dizini için). Eklenti `INTERNET` ve `ACCESS_NETWORK_STATE` izinlerini ekler; `com.android.installreferrer:installreferrer:2.2` kullanır. Web ve masaüstü desteklenmez.

Eklenti `sdks/android` AAR'ına bağlanmaz: pub.dev paketi yayınlanmamış Maven koordinatına veya depo dışı yola dayanamaz. Resmî referrer kütüphanesini doğrudan kullanır.

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Feralin.initialize(const FeralinConfig(
    projectKey: 'pk_live_...', // yalnız x-feralin-project-key başlığında taşınır
    collectUrl: 'https://collect.example.com',
    // consent verilmezse izin bekleniyor sayılır
  ));
  runApp(const MyApp());
}
```

`sk_` ile başlayan gizli anahtar reddedilir ve SDK kapalı kalır. Hiçbir metot uygulamaya hata fırlatmaz.

## İzin akışı

SDK kararı saklamaz. Kararın sahibi uygulama veya CMP'sidir; her açılışta `consent` ile veya `setConsent` ile bildirilir.

| Durum | Davranış |
|---|---|
| `consent` yok (bekleniyor) | Olay üretilmez, gönderilmez, depodaki kuyruk silinmez. Gelen bağlantı temizlenmiş halde yalnız bellekte bekler |
| `Consent(analytics: false)` | Olay üretilmez, kuyruk ve depodaki anonim kimlik silinir |
| `Consent(analytics: true)` | Olaylar gider. **Attribution yok** |
| `Consent(analytics: true, advertising: false)` | Olaylar gider. **Attribution yok**, sonradan izin gelse de eski bağlantı kanıtı saklanmamıştır |
| `Consent(analytics: true, advertising: true)` | Olaylar ve attribution kanıtı gider |

```dart
await Feralin.setConsent(const Consent(analytics: true, advertising: true));
Feralin.getStatus().consent?.advertising; // verilen değer; verilmediyse null
```

`advertising` varsayılan olarak `true` sayılmaz; verilmediyse olayda alan bulunmaz.

**iOS ATT:** Bu SDK ATT izin penceresi göstermez ve `ATTrackingManager` çağırmaz. iOS'ta ATT kararının sahibi uygulamadır. İzin penceresini uygulamanız gösterir, sonucu `advertising` olarak bildirir: yalnız `authorized` ise `true`; `denied`, `restricted` veya henüz sorulmadıysa `true` vermeyin. ATT kararı değişirse `setConsent` çağırın. SDK bu değeri doğrulamaz.

### İzin yoksa attribution yok

`fr_click`, `utm_*` ve Play Install Referrer okuma yalnız `consent.advertising == true` iken kullanılır. Aksi halde:

- Referrer hiç okunmaz.
- `app_first_open` ve `deep_link_opened` üretilir, ama `attribution_source=none` taşır; `fr_click` ve `utm_*` yoktur. Sunucu bu olaylardan tıklama eşlemez.
- Uygulama `track` ile kendi `fr_click` özelliğini verse de çıkarılır.
- İzin geri çekilirse kuyrukta bekleyen `app_first_open` ve `deep_link_opened` kaybolmaz: `fr_click` ve `utm_*` çıkarılır, `attribution_source=none` olur, izin bloğu güncellenir. Uygulama olaylarından yalnız `fr_click` çıkarılır. Yalnız kanıt taşıyan `consent_followup` olayı silinir.

İzin sonradan `true` olursa:

- İlk açılış kanıtsız gönderildiyse referrer o zaman, kurulumda bir kez okunur. Kanıt varsa `deep_link_opened` olayı `attribution_source=play_install_referrer`, `fr_click`, `consent_followup=true` ve `first_open_at` ile gider. `app_first_open` kurulum başına tek olduğu için tekrar üretilmez. Sunucu geriye bakış penceresini izin anına değil `first_open_at` değerine göre değerlendirir.
- Aynı süreçte, izin henüz bildirilmemişken açılmış bağlantının kanıtı bellekte beklemişse `deep_link_opened` kanıtla ve `consent_followup=true` ile gider. Bu olay ikinci bir açılış değildir; sunucu `consent_followup` ile açılış toplamından ayırır. Açık `advertising: false` sonrası veya süreç bittikten sonra bağlantı kanıtı kalmaz.

## Kullanım

```dart
Feralin.track('purchase', {'amount': 10.5});
Feralin.screen('home');
Feralin.identify('kullanici_42'); // PII vermeyin
final result = await Feralin.flush(); // result.status: HTTP durumu, 0: istek yok veya ağ hatası
await Feralin.reset(); // çıkış: kimlikler yenilenir, kuyruk ve global özellikler silinir
```

### Kimlik yöntemleri (UTP §8.2)

```dart
Feralin.setGlobalProperties({'app_release': '2.4.0'}); // fr_ ile başlamayan her olaya eklenir
Feralin.setUserProperties({'plan': 'pro', 'seats': 12}); // fr_user_properties
Feralin.group('acme-team', {'plan': 'team'}); // fr_group, group_id + özellikler
Feralin.clearGlobalProperties();
```

Anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, çağrı başına en çok 50 özellik; değer dizge (≤256 karakter, e-posta biçimi değil), sonlu sayı ya da mantıksal. Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) ve `verified` gibi doğrulama alanları istemcide düşer; geçerli özellik kalmazsa olay üretilmez. `group_id` 1-128 karakter, `@` ve kontrol karakteri içermez. Global özellikte `null` anahtarı siler, toplam en çok 50 anahtar, olayın kendi özelliği aynı anahtarda kazanır. Toplayıcı yalnız projenin özellik izin listesindeki anahtarları saklar; liste boşsa olay sayılır ama özellik saklanmaz.

| Olay | Ne zaman | `attribution_source` |
|---|---|---|
| `app_first_open` | Analitik izni olan ilk çalıştırmada, kurulum başına bir kez | `play_install_referrer`, `app_link`, `universal_link` veya `none` |
| `deep_link_opened` | Her bağlantı açılışında | `app_link` veya `universal_link` (izin yoksa `none`), izin sonrası takip olayında `play_install_referrer` de olabilir |

`platform` değeri `flutter_android` veya `flutter_ios`. Play'in tıklama yokken döndürdüğü `utm_medium=organic` ve `(not set)` kanıt sayılmaz.

### Android App Links

Etkinliğin `ACTION_VIEW` http(s) niyetleri kanaldan otomatik gelir; `handleDeepLink` çağırmayın, aynı açılış iki kez sayılır. Başka bir bağlantı paketi kullanıyorsanız `autoCaptureDeepLinks: false` verip URL'i `handleDeepLink` ile iletin. Alan doğrulaması (`autoVerify`, `assetlinks.json`) uygulamanındır.

### Fera Fly kısa linkleri

Uygulama `https://fera.fly/kod` ya da `https://marka.fera.fly/kod` gibi bir kısa linkle doğrudan açıldığında (App Link / Universal Link) işletim sistemi yönlendiriciye uğramaz. SDK aynı adresi `Accept: application/vnd.feralin.link+json` ile ister ve linkin derin yolunu, UTM'sini ve reklam izni varsa tıklama kimliğini alır; bunlar `deep_link_opened` olayına eklenir. Analitik izni yoksa ya da izin henüz verilmediyse istek yapılmaz; reklam izni yoksa istek `Feralin-Attribution: off` ile gider ve yönlendirici kanıt yazmaz.

```dart
final open = await Feralin.handleShortLink(uri); // iOS'ta ya da autoCaptureDeepLinks: false iken
navigator.pushNamed(open.destination);           // ör. /urun/42
```

Android'de otomatik yakalama açıkken kısa link zaten çözümlenir; gidilecek yolu `Feralin.lastShortLink?.destination` verir. `handleShortLink` ile `handleDeepLink` aynı açılışı sayar, ikisinden yalnız birini çağırın. Markalı alanınız varsa `FeralinConfig(shortLinkHosts: ['fera.fly', 'go.marka.com'])`. `destination` dışarıdan gelen veridir; kendi yönlendirme tablonuzla eşleştirin.

### Ertelenmiş derin bağlantı (yalnız Android)

Uygulama kurulu değilken tıklanan linkin uygulama içi yolu (`deep_link_path`) Play kurulumundan sonra bir kez teslim edilir:

```dart
final link = await Feralin.consumeDeferredDeepLink();
if (link.status == DeferredDeepLinkStatus.delivered) router.go(link.path!);
```

Attribution açık link ve reklam ölçümü izni gerekir (`consentRequired`). iOS'ta sonuç her zaman `notSupported`: App Store parametreyi kuruluma taşımaz, parmak iziyle eşleştirme yasaktır. Yol olaya yazılmaz; dışarıdan gelen veridir, kendi yönlendirme tablonuzla eşleştirin. Birim testlidir, gerçek Play kurulumuyla sınanmadı.

### iOS sınırları (`unknown`)

Bu pakette yerel iOS kodu yalnız kuyruk şifreleme anahtarı içindir (Keychain, `FeralinFlutterPlugin.swift`; derlenmedi). AdServices, SKAdNetwork ve AdAttributionKit köprüsü bulunmaz.

`Feralin.bindInstall()` (F3-E02-T02, ADR-0007) AdServices token'ını `com.feralin/flutter` kanalındaki `getAdServicesToken` çağrısından ister, `FeralinConfig.attribution` adresine kurulum kimliğiyle gönderir ve `InstallBinding(installId, adServices)` döndürür. Reklam ölçümü izni yoksa `skippedNoConsent` ve kimlik yok. Android'de ve iOS yerel eklentisi yokken (bu pakette yok) `AdServicesStatus.unsupported` döner: dürüst no-op. `installId`'yi kendi sunucunuza iletin; sunucu gizli API anahtarıyla `POST /v1/projects/{id}/attribution/account-links` (`surface=app`, `subject_id=<installId>`) çağırır. Sunucu bugün Apple'a sormaz: sonuç atıf kararı değildir. Dart tarafı birim testli, iOS yerel eklentisi derlenmedi.

- Evrensel bağlantıyı uygulama verir: `await Feralin.handleDeepLink(uri);` kaynak `universal_link` olur. Bu tek başına kurulum kaynağını kanıtlamaz.
- Kanıt yoksa `attribution_source=none` gider ve sunucu kararı `unknown` olur. `unknown`, "organik" demek değildir; kaynak bilinmiyor demektir.
- Normal web, App Store, kurulum zinciri kesin tekil attribution vermez ve bu SDK bunu vaat etmez. Parmak izi kullanılmaz.
- Uygulama sürümü iOS'ta otomatik okunmaz; `FeralinConfig.appVersion` ve `appBuild` ile verin. Saat dilimi gönderilmez.
- Depo `getApplicationSupportDirectory` altındadır ve yedeklemeye girebilir; geri yüklemede ilk açılış işareti korunur.
- Ağ dinleyicisi yoktur; kuyruk ön plana dönüşte ve geri çekilme süresi sonunda boşalır.

`flutter build ios` burada yapılamaz. Yukarıdaki iOS davranışının çekirdeği Dart testleriyle sınandı; gerçek iOS çalıştırması yapılmadı.

## Hata, oyun ve reklam geliri (X4)

- **Hata:** `Feralin.captureError(error, stack)` yakalanan hatayı, `Feralin.captureUncaughtErrors(sampleRate: 1)` yakalanmamış Flutter ve Dart hatalarını (`FlutterError.onError`, `PlatformDispatcher.onError`) `fr_error` olarak bildirir. Mevcut işleyiciler korunur ve çağrılmaya devam eder. Giden alanlar: tür adı, temizlenmiş mesaj, normalize çerçevelerin özeti `fingerprint` (satır, sütun ve paket yolu gitmez), `top_frame`, `app_version`. Süreç başına en çok 20 olay, aynı parmak izi için 3. Yerel (native) çökme yakalanmaz; sembolleştirme yoktur (`--obfuscate` ile derlenmiş uygulamada gizlenmiş adlar olduğu gibi gider).
- **Oyun:** `trackLevelStart/Complete/Fail`, `trackEconomySource/Sink` (sanal para birimi; gerçek gelir değildir), `trackRewardedAdShown/Complete`, `trackIapOfferShown/Initiated`. Sözleşme `packages/schemas/utp/v1/game-events.md`; sözleşme dışı girdide `null` döner ve olay üretilmez.
- **Reklam geliri:** `Feralin.trackAdRevenue(AdRevenueInput(network: 'admob', adFormat: AdFormat.rewarded, revenueMicros: 12500, currency: 'USD'))`. `fr_ad_revenue` ayrı bir gelir sınıfıdır: satın alma gelirine (`trackRevenue`) ve reklam harcamasına karışmaz; istemci beyanıdır ve sunucuda `ESTIMATED` kalır (reklam ağı mutabakatı `BLOCKED_EXTERNAL`).
- Birim testlidir (`signal_events_test.dart`); gerçek cihazda sınanmadı.

### Kurulum mağazası (yalnız Android)

İlk açılış olayı (`app_first_open`) Android'de `install_store` özelliğini taşır: uygulamayı cihaza kuran paketten türetilen kapalı listeden bir değer (`google_play`, `samsung_galaxy_store`, `huawei_appgallery`, `amazon_appstore`, `xiaomi_getapps`, `oppo_app_market`, `vivo_app_store`, `honor_app_market`, `sideload`, `unknown`, `other`). Yapılandırma gerekmez. Kişisel veri ya da atıf kanıtı olmadığından reklam ölçümü izninden bağımsız eklenir (analitik izni yine şarttır). Listede olmayan kurucunun paket adı gönderilmez (`other`); sınıflama yerel tarafta yapılır, Dart kapalı listeyi yeniden denetler. Değer işletim sisteminin bildirdiğidir, mağaza tarafından doğrulanmaz. Okunamazsa alan eklenmez, ilk açılış yine üretilir. iOS'ta alan yoktur. Birim testlidir (`InstallStoreTest.kt`, `install_store_test.dart`); gerçek cihazda sınanmadı.

### SDK imzası, emülatör işareti ve Huawei AppGallery (18 Kasım 2026)

- **SDK imzası:** `FeralinConfig(signingKey: SigningKey(id: 'sgn_...', secret: 'fsk_...'))` verilirse yalnız `app_first_open` ve `deep_link_opened` olaylarına `fr_sig` eklenir (`v1.<kimlik>.<unix saniye>.<hex hmac-sha256>`; olay kimliğine ve `anonymous_id` değerine bağlıdır). Sunucu imzasız ya da bozuk imzalı kurulumu projenin kuralına göre işaretler ya da reddeder. Kimlik `sgn_` + 12-40 küçük harf/rakam, değer 16-200 karakter olmalıdır; geçersiz anahtarda SDK kapalı kalır (`initialize` `false`). Anahtar değeri loglara ve `toString` çıktısına düşmez. Anahtar uygulamaya gömülüdür: imza sahte kurulumu zorlaştırır, imkânsız kılmaz. Paket bağımlılık eklemez; HMAC-SHA256 saf Dart'tır ve sunucuyla aynı sınama vektörüyle doğrulanır (`fraud_signals_test.dart`).
- **Emülatör işareti (yalnız Android):** yerel eklenti `android.os.Build` alanlarını sınıflar; emülatörse `app_first_open` olayına `device_emulator: true` eklenir, değilse alan yoktur. `Build` alanlarının kendisi Dart'a geçmez. Sezgiseldir: sunucuda kesin kanıt değil, işarettir. iOS'ta alan yoktur.
- **Huawei AppGallery kurulum yönlendiricisi (yalnız Android):** Play Install Referrer kanıt vermezse (hizmet yok, boş ya da organik varsayılan) AppGallery'nin içerik sağlayıcısındaki `referrer` değeri okunur; kanıt `attribution_source=huawei_install_referrer` ile gider. Yalnız reklam ölçümü izni açıkken okunur ve aynı izin listesinden (`fr_click`, `fr_dl`, `utm_*`) geçer. Eklenti `<queries>` içinde `com.huawei.appmarket` paketini kendi manifestinden birleştirir.

Üçü de birim testlidir (`fraud_signals_test.dart`, `platform_channel_test.dart`, `EmulatorCheckTest.kt`, `HuaweiInstallReferrerTest.kt`); gerçek cihazda (özellikle Huawei cihazında) denenmedi. AppGallery sütun sırası Huawei belgesinden alınmıştır.

## Gizlilik sınırları

- Toplanmaz: IP, reklam kimliği, cihaz modeli, ekran, işletim sistemi sürümü. `User-Agent` yalnız SDK adı ve sürümüdür.
- Referrer'dan yalnız `fr_click` ve `utm_source|medium|campaign|term|content` okunur. Süzme yerel tarafta yapılır ve Dart'ta yinelenir; ham dizgi saklanmaz, loglanmaz.
- URL'de sorgu ve parça gönderilmez; `page_url` yalnız scheme, host ve path taşır.
- Android'de depo `noBackupFilesDir` altındadır. Kuyruktaki olay gövdeleri diskte AES-256-GCM ile şifrelidir (aşağıda).
- Anonim kimlik izin verilmeden diske yazılmaz.

## Kuyruk şifrelemesi

Olay gövdeleri diskte `queue.jsonl` içinde şifreli tutulur. Satır `{"event_id":"…","enc":"enc1:…"}` biçimindedir: `enc1:` + onaltılı(IV ‖ şifreli metin ‖ GCM etiketi), AES-256-GCM, ilişkilendirilmiş veri olay kimliğidir. Bu, Android çekirdeğindeki `EncryptedEventStore` satır biçimiyle aynıdır; satır başka bir olay kimliğine taşınırsa açılmaz. Olay kimliği açık kalır (tekrar gönderimde aynı `event_id` ve tekilleştirme için).

- **Anahtar:** Android'de Android Keystore (`com.feralin.sdk.flutter.queue.v1`, dışarı aktarılamaz, yedekle taşınmaz), iOS'ta Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`). Şifreleme ve çözme yerel tarafta yapılır (`encryptQueue`, `decryptQueue` kanal çağrıları); anahtar Dart'a hiç geçmez. Bu yüzden kuyruk, kurulum başka cihaza geri yüklense de açılmaz.
- **Anahtar alınamazsa** (Keystore/Keychain hatası, yerel eklenti yok) düz metne düşülmez: olaylar yalnız bellekte tutulur, kuyruk dosyasına yazılmaz ve mevcut şifreli dosyaya dokunulmaz; anahtar sonraki açılışta gelirse dosya okunur. İzin geri çekilince (`optOut`, `analytics=false`) kuyruk dosyası anahtar olmasa da silinir.
- **Eski sürümden geçiş:** 0.1.0'ın düz metin satırları ilk okumada şifreli yazılır; açılamayan (bozuk, anahtarı kayıp) satır atılır.
- Anahtar-değer alanı (anonim kimlik, ilk açılış işaretleri) olay gövdesi değildir ve `state.json` içinde olduğu gibi kalır.
- **Sınanma durumu:** Dart tarafı (dosya, bellek, anahtarsız mod, geçiş) birim testlidir; Kotlin şifreleyici JVM'de AES-256-GCM ile sınandı (Python `cryptography` ile üretilmiş `enc1:` satırı açılır). Keystore yolu gerçek cihazda, iOS Swift eklentisi (`ios/Classes/FeralinFlutterPlugin.swift`) ise hiç derlenmedi ve koşmadı (macOS ve Xcode yok).

## Gönderim ve pil

Kuyruk en fazla 1000 olay tutar. Tek istekte en fazla 500 olay (varsayılan 50) ve 900 KB gider. `202` ve kalıcı `4xx` kuyruktan siler; `429`, `5xx` ve ağ hatası tutar. Yeniden deneme üstel (5 sn ile 15 dk, jitter) ve `Retry-After` uyumludur; sonucu bilinmeyen batch aynı içerik ve aynı `Idempotency-Key` ile denenir. Anahtar, Web SDK ile aynı özettir.

Olay eklemek dosyaya yalnız satır ekler. Kuyruk boşken zamanlayıcı yoktur. `paused` geçişinde bir kez gönderim denenir, sonra yeniden deneme durur; kalan olaylar sonraki açılışta gider.

## Geliştirme

```bash
cd sdks/flutter
flutter analyze
flutter test
dart pub publish --dry-run   # yayın yapmaz
(cd example && flutter build apk)
DATABASE_URL='postgres://kullanici:parola@127.0.0.1:5432/test_db?sslmode=disable' scripts/e2e-collect.sh
```

`test/collector_e2e_test.dart` ortam değişkenleri yoksa atlanır; atlanma doğrulama sayılmaz. Yalnız test veritabanı kullanın. Örnek uygulama için `example/README.md`.

## Meta Install Referrer (Android)

Facebook ya da Instagram reklamından gelen kurulumun kampanya, reklam seti ve reklam bilgisi Meta'nın kendi verisinden okunur; Facebook SDK
gerekmez. Yapılacaklar:

1. Feralin panelinde Atıf ekranındaki Meta kartına Facebook App ID'yi ve Meta uygulama panelindeki Install Referrer çözme anahtarını girin.
2. SDK yapılandırmasına Facebook App ID'yi verin (`metaAppId`; Unity'de `FeralinBehaviour` alanı ya da `FeralinOptions.MetaAppId`).
3. Android 11 ve üzerinde uygulama manifestine paket görünürlüğü ekleyin (Android SDK ve Flutter eklentisi bunu kendi manifestinden
   birleştirir; Unity'de `Assets/Plugins/Android/AndroidManifest.xml` içine elle eklenir):

```xml
<queries>
    <package android:name="com.facebook.katana" />
    <package android:name="com.instagram.android" />
    <package android:name="com.facebook.lite" />
</queries>
```

Veri yalnız reklam ölçümü izni (`consent.advertising`) açıkken okunur; içerik şifrelidir ve uygulamada açılmaz.
