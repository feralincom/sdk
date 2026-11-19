# cordova-plugin-feralin

Feralin ölçüm SDK'sının Cordova eklentisi. JS yüzü (`window.Feralin`) yalnız doğrulama yapar; kuyruk, izin, kimlik, idempotency ve yeniden deneme yerel çekirdeklerdedir: Android'de Feralin Android SDK'sı (`sdks/android`, Kotlin AAR), iOS'ta Feralin Swift SDK'sı (`sdks/swift`). Hiçbir yöntem hata fırlatmaz ya da reddedilen Promise döndürmez.

## Durum

| Konu | Durum |
|---|---|
| JS yüzü ve tip bildirimleri | Birim testli (`node --test`, sahte `cordova/exec`), `tsc --noEmit` geçiyor |
| Android köprüsü (`src/android/FeralinPlugin.java`) | `javac` ile cordova-android 14.0.1 çerçeve kaynağına, Android 36 `android.jar` ve gerçek Feralin AAR'ına karşı derlendi. Gerçek Cordova uygulamasında, emülatörde ya da cihazda **çalıştırılmadı** |
| iOS ortak köprüsü (`src/ios/Plugin/FeralinBridge.swift`) | Feralin Swift çekirdeğiyle Linux'ta (Swift 6.4.2) derlendi, 7 XCTest geçti (`scripts/check-ios-bridge.sh`). UIKit yaşam döngüsü ve Darwin'e özgü dallar Linux'ta derlenmez |
| iOS Cordova sarmalayıcısı (`FeralinCordovaPlugin.swift`) | **Derlenmedi**: Cordova çerçevesi ve iOS hedefi için Mac ve Xcode gerekir (`BLOCKED_EXTERNAL`) |
| Olayın toplayıcıya ulaşması | **Sınanmadı**: gerçek Cordova uygulaması, emülatör ve iPhone gerekir |
| npm yayını | Yapılmadı; site sahibinin açık onayı gerekir |

Olaylar Android'de `platform=android`, `sdk=feralin-android` ile gider: Android çekirdeği sarmalayıcı platformu olarak bugün yalnız `react_native` kabul eder ve toplayıcı şemasında `cordova` değeri yoktur. iOS'ta `platform=ios`, `sdk=cordova-plugin-feralin` gider.

## Gereksinimler

- Cordova CLI 12+, cordova-android 13+ (minSdk 24), cordova-ios 8+ (Swift Package eklentisi).
- iOS dağıtım hedefi en az 14.0: uygulamanın `config.xml` dosyasına `<preference name="deployment-target" value="14.0" />` ekleyin (Feralin Swift çekirdeği iOS 14 ister).

## Kurulum

Paket npm'de yayımlı değildir. Depodan yerel kurulum:

```bash
cd sdks/cordova
node scripts/vendor.mjs          # Swift çekirdeğini kopyalar, Android AAR'ını derleyip kopyalar
cd /path/to/your-cordova-app
cordova plugin add /path/to/Feralin.com/sdks/cordova
```

`scripts/vendor.mjs` Android için `sdks/android` içinde `:feralin:assembleRelease` koşar (Android SDK gerekir; `ANDROID_HOME` yoksa Android Studio'nun varsayılan dizini denenir). Kopyalar `.gitignore` kapsamındadır.

## Kullanım

```js
document.addEventListener("deviceready", async () => {
  const ready = await Feralin.initialize({
    projectKey: "pk_live_...",                 // yalnız public anahtar; sk_ reddedilir
    collectUrl: "https://collect.example.com",
    consent: kayitliKarar(),                   // CMP'nizin saklı kararı
    attribution: { apiUrl: "https://api.example.com", projectId: "prj_..." }, // iOS ertelenmiş derin bağlantı için
  });
  if (!ready) return;

  await Feralin.trackFirstOpen();              // iOS: kurulum başına bir kez; Android: "automatic"
  await Feralin.track("level_up", { level: 3 });
  await Feralin.identify("kullanici_42");      // PII vermeyin
  await Feralin.trackRevenue({ transactionId: "order_1", amountMinor: 4999, currency: "TRY" });

  const link = await Feralin.consumeDeferredDeepLink();
  if (link.status === "delivered") router.open(link.path); // yolu kendi tablonuzla eşleştirin
});
```

### İzin

| Durum | Android | iOS |
|---|---|---|
| `consent` verilmedi | İzin bekleniyor: olay üretilmez, kuyruk silinmez | Analitik kapalı sayılır: olay üretilmez, diskteki kuyruk silinir. Saklı kararı her açılışta verin |
| `{ analytics: false }` / `optOut()` | Kuyruk ve anonim kimlik silinir | Kuyruk, kurulum kimliği ve köprünün "ilk açılış gönderildi" kaydı silinir |
| `{ analytics: true, advertising: true }` | Olaylar ve atıf kanıtı gider | Olaylar gider; ATT izni yoksa reklam izni kapalı sayılır |

### İlk açılış, mağaza ve derin bağlantı

- `trackFirstOpen()`: iOS'ta `app_first_open` kurulum başına bir kez gider ve iOS 17.4+ cihazda `install_store` (App Store, TestFlight, alternatif pazar yeri) eklenir. Android çekirdeği ilk açılışı Play Install Referrer, App Link ve kurulum mağazasıyla kendisi üretir; yöntem `automatic` döner.
- `getInstallStore()`: iOS'ta `FeralinInstallSource.current()`; Android'de `null` (çekirdek değeri ilk açılışa kendisi ekler).
- App Link (Android) otomatik yakalanır: eklenti `onNewIntent` niyetlerini çekirdeğe iletir. iOS Universal Link'i Cordova kendisi iletmez; `AppDelegate` içinde aldığınız adresi `Feralin.handleUniversalLink(url)` ile verin. Fera Fly kısa linki için `handleShortLink(url)`.
- `consumeDeferredDeepLink(callback?)`: yol bir kez teslim edilir. iOS'ta `attribution` yapılandırması yoksa `not_configured`, reklam ölçümü izni yoksa `consent_required` döner. iOS'ta App Store parametreyi kuruluma taşımaz; eşleşme sunucu kararıdır, parmak izi kullanılmaz.

### Kaldırma ölçümü

```js
Feralin.setPushToken(token);                 // Android: FCM kayıt belirteci; iOS: APNs belirtecinin onaltılı yazımı
if (Feralin.isUninstallCheck(message.data)) return; // Feralin'in sessiz bildirimi: kullanıcıya göstermeyin
```

## Geliştirme

```bash
cd sdks/cordova
node --test test/*.test.mjs                                   # JS birim testleri ve kaynak tutarlılığı
node ../../node_modules/typescript/bin/tsc -p tsconfig.json   # tip bildirimleri
SWIFT_BIN=~/.local/share/swift-6.4.2/usr/bin bash scripts/check-ios-bridge.sh   # WSL ya da macOS
```

Ortak iOS köprüsü `src/ios/Plugin/FeralinBridge.swift`, `sdks/capacitor/ios/Sources/FeralinCapacitorPlugin/FeralinBridge.swift` ile birebir aynıdır; Capacitor testleri iki dosyayı karşılaştırır.

## English

Cordova plugin for Feralin. The JS facade (`window.Feralin`) validates input and forwards to the native cores: the Feralin Android SDK (Kotlin AAR, `sdks/android`) and the Feralin Swift SDK (`sdks/swift`, as a Swift package for cordova-ios 8). No method throws or rejects.

Verification status: JS unit tests and type check pass; the Android bridge compiles with `javac` against cordova-android 14.0.1 and the real Feralin AAR; the shared iOS bridge compiles and passes XCTest on Linux. The Cordova iOS wrapper is **not compiled** (needs a Mac and Xcode), and no build has run in a real Cordova app, emulator or device, so event receipt is **not verified**. Not published to npm.

Install locally with `node scripts/vendor.mjs` and `cordova plugin add <path>`. Set `deployment-target` to 14.0 for iOS. On Android, events are reported as `platform=android` until the collector schema gains a Cordova platform value. `trackFirstOpen()` sends `app_first_open` once per install on iOS (with `install_store` on iOS 17.4+); on Android the core emits it automatically. Use `consumeDeferredDeepLink()`, `handleUniversalLink(url)`, `handleShortLink(url)`, `setPushToken(token)` and `isUninstallCheck(data)` as documented above.
