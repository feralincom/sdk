<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Dart / Flutter: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/flutter/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Dart |
| Paket | `feralin_flutter` |
| Sürüm | 0.2.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/flutter` |
| Registry | pub.dev: **BLOCKED_EXTERNAL** (gereken: Doğrulanmış pub.dev yayıncısı) |
| Derleme | `cd sdks/flutter && flutter pub get` |
| Test | `cd sdks/flutter && flutter test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `pub.dev` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```yaml
dependencies:
  feralin_flutter:
    path: ../sdks/flutter
```

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

## İlk kullanım

```dart
Feralin.track('purchase', {'amount': 10.5});
Feralin.screen('home');
Feralin.identify('kullanici_42'); // PII vermeyin
final result = await Feralin.flush(); // result.status: HTTP durumu, 0: istek yok veya ağ hatası
await Feralin.reset(); // çıkış: kimlikler yenilenir, kuyruk ve global özellikler silinir
```

```dart
Feralin.setGlobalProperties({'app_release': '2.4.0'}); // fr_ ile başlamayan her olaya eklenir
Feralin.setUserProperties({'plan': 'pro', 'seats': 12}); // fr_user_properties
Feralin.group('acme-team', {'plan': 'team'}); // fr_group, group_id + özellikler
Feralin.clearGlobalProperties();
```

```dart
final link = await Feralin.consumeDeferredDeepLink();
if (link.status == DeferredDeepLinkStatus.delivered) router.go(link.path!);
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız; oyun olayı yöntemleri trackLevelStart/Complete/Fail, trackEconomySource/Sink, trackRewardedAdShown/Complete, trackIapOfferShown/Initiated birim testli) |
| batch | PARTIAL (kalıcı dosya kuyruğu; olay gövdeleri diskte AES-256-GCM ile şifreli, satır biçimi Android çekirdeği EncryptedEventStore ile aynı (enc1: onaltılı IV‖şifreli metin‖etiket, ilişkilendirilmiş veri event_id); anahtar Android Keystore ve iOS Keychain yerel köprüsünde kalır, anahtar alınamazsa düz metne düşülmez, olaylar bellekte kalır; eski düz metin satırlar ilk okumada şifrelenir; Dart tarafı birim testli, Kotlin şifreleyici JVM AES-GCM ve Python üretimi enc1 satırıyla sınandı; Keystore gerçek cihazda sınanmadı, iOS Keychain eklentisi derlenmedi; kimlik ve işaret alanları şifresiz) |
| consent | SUPPORTED (yayınsız) |
| identity | PARTIAL (identify, reset, group, setUserProperties, setGlobalProperties/clearGlobalProperties; fr_group ve fr_user_properties olayıdır, toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar; birim testli, gerçek cihazda ve gerçek collect ile koşmadı) |
| attribution | PARTIAL (Android Play Referrer yazıldı, gerçek Play tıklamasıyla sınanmadı; iOS yerel köprü yok, kanıt yoksa `none`; iOS `bindInstall` AdServices token ve kurulum kimliği Dart'ta yazıldı ve birim testli, yerel iOS eklentisi yok: token `unsupported`; Android'de `unsupported` no-op) |
| deeplink | PARTIAL (Android App Links ve ertelenmiş yol teslimi; gerçek Play kurulumuyla sınanmadı; iOS ertelenmiş `not_supported`, yalnız uygulamanın verdiği URL) |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; trackAdRevenue → fr_ad_revenue (ayrı gelir sınıfı: satın alma gelirine ve reklam harcamasına karışmaz; istemci beyanı, sunucuda ESTIMATED, reklam ağı mutabakatı BLOCKED_EXTERNAL)) |
| error | PARTIAL (captureError ve captureUncaughtErrors → fr_error, FlutterError.onError ve PlatformDispatcher.onError, yığın çerçeve parmak izi, örnekleme ve sınır, birim testli; yerel çökme yok, sembolleştirme yok) |
| replay | N/A (mobil replay F7 öncesi yok) |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS | Android release APK; iOS derlenemez, macOS yok. |
| test | PASS | flutter analyze temiz, flutter test: 121 test (şifreli kuyruk, anahtarsız mod, eski satır geçişi dahil); Kotlin QueueCipher 5 JVM testi. |
| registry | BLOCKED_EXTERNAL | pub.dev yayıncısı yok; pub publish --dry-run koşar, yayın yapılmaz. |
| clean_install | PASS | 13 Kasım 2026: scripts/e2e-emulator.mjs git: flutter create ile boş proje, paket pub.dev dışından git kaynağıyla (HEAD paket ağacından kurulan yerel file:// git deposu, pubspec.lock source: git ve resolved-ref) kuruldu, release APK emülatörde olay gönderdi ve ClickHouse satırı doğrulandı. pub.dev ve uzak git barındırma (GitHub) sınanmadı. |
| event_receipt | PASS | scripts/e2e-collect.sh ve API 36 emülatör. 13 Kasım 2026: scripts/e2e-emulator.mjs example ve git: emülatörde init, izin, ilk açılış (adb kurulumu, kaynak none), screen_view, feralin_purchase, ağ kesikken kuyruk, ağ gelince gönderim; gerçek services/collect outbox, collect worker ve ClickHouse FINAL satırları tam bir kez; video ve ClickHouse çıktısı tests/e2e/screenshots/mobile altında (git dışı). Emülatördür, gerçek cihaz değil: SDK-R07 BLOCKED_EXTERNAL. |
| documentation | PASS | docs/sdk/flutter.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
