# @feralin/capacitor

Feralin ölçüm SDK'sının Capacitor eklentisi (Capacitor 7+, Capacitor 8.6 ile tip denetimi yapıldı). Uygulama yalnız `Feralin` nesnesini kullanır; doğrulama TypeScript katmanındadır, davranış yerel çekirdeklerdedir: Android'de Feralin Android SDK'sı (`sdks/android`), iOS'ta Feralin Swift SDK'sı (`sdks/swift`), tarayıcıda (`capacitor serve`, PWA) Feralin Web SDK'sı (`@feralin/web`). Hiçbir yöntem hata fırlatmaz ya da reddedilen Promise döndürmez.

## Durum

| Konu | Durum |
|---|---|
| TypeScript katmanı ve web yedeği | 14 birim testi geçiyor (sahte yerel eklenti, sahte ve gerçek `@feralin/web` derlemesi); `tsc` `skipLibCheck: false` ile `@capacitor/core` 8.6.0 ve `@feralin/web` bildirimlerine karşı geçti |
| Android köprüsü (`android/src/main/java/com/feralin/capacitor/FeralinPlugin.java`) | `javac` ile @capacitor/android 8.6.0 kaynağına, Android 36 `android.jar` ve gerçek Feralin AAR'ına karşı derlendi (Capacitor'ın kendi sıçrama ekranı sınıfları yerel önbellekte eksik kitaplık yüzünden derlenmedi; eklenti sınıfı hatasız). Gradle ile gerçek Capacitor uygulamasında **derlenmedi**, emülatörde ve cihazda **çalıştırılmadı** |
| iOS ortak köprüsü (`FeralinBridge.swift`) | sdks/cordova kopyasıyla birebir aynı; Linux'ta Feralin Swift çekirdeğiyle derlendi, 7 XCTest geçti |
| iOS Capacitor sarmalayıcısı (`FeralinPlugin.swift`) | **Derlenmedi**: Capacitor çerçevesi ve iOS hedefi için Mac ve Xcode gerekir (`BLOCKED_EXTERNAL`) |
| Olayın toplayıcıya ulaşması | Uygulama içinde **sınanmadı** (emülatör, iPhone ve Capacitor uygulaması gerekir) |
| npm yayını | Yapılmadı; site sahibinin açık onayı gerekir |

Android'de olaylar `platform=android`, `sdk=feralin-android`; iOS'ta `platform=ios`, `sdk=@feralin/capacitor`; web'de `platform=web`, `sdk=@feralin/web` ile gider. Toplayıcı şemasında ayrı bir Capacitor platform değeri yoktur.

## Kurulum

Paket npm'de yayımlı değildir. Depodan yerel kurulum:

```bash
cd sdks/capacitor
node scripts/vendor.mjs                      # Swift çekirdeği → ios/Sources/Feralin, Android çekirdeği → android/maven-repo
npm install --no-save @capacitor/core@8 @feralin/web@0.1.0 && npm run build   # dist/esm
cd /path/to/your-capacitor-app
npm install /path/to/Feralin.com/sdks/capacitor
npx cap sync
```

iOS dağıtım hedefi en az 15.0 (Capacitor 8). Swift Package (`Package.swift`) ve CocoaPods (`FeralinCapacitor.podspec`) desteklenir.

## Kullanım

```ts
import { Feralin } from "@feralin/capacitor";

const ready = await Feralin.initialize({
  projectKey: "pk_live_...",                   // yalnız public anahtar; sk_ reddedilir
  collectUrl: "https://collect.example.com",
  consent: savedConsent(),                     // CMP'nizin saklı kararı
  attribution: { apiUrl: "https://api.example.com", projectId: "prj_..." }, // iOS ertelenmiş derin bağlantı için
});

await Feralin.trackFirstOpen();                // iOS: kurulum başına bir kez; Android: "automatic"; web: "not_supported"
await Feralin.track("level_up", { level: 3 });
await Feralin.trackRevenue({ transactionId: "order_1", amountMinor: 4999, currency: "TRY" });

const link = await Feralin.consumeDeferredDeepLink();
if (link.status === "delivered" && link.path) router.push(link.path); // yolu kendi tablonuzla eşleştirin

// Kaldırma ölçümü (push eklentinizden gelen belirteç ve ileti verisi)
await Feralin.setPushToken(token);             // Android: FCM belirteci; iOS: APNs belirtecinin onaltılı yazımı
if (Feralin.isUninstallCheck(notification.data)) return;
```

- İzin: Android ve web'de `consent` verilmezse izin bekleniyor sayılır. iOS'ta verilmezse analitik kapalı sayılır ve diskteki kuyruk silinir; saklı kararı her açılışta verin.
- Derin bağlantı: Android App Link niyetleri (`handleOnNewIntent`) ve iOS Universal Link'leri (`capacitorOpenUniversalLink` bildirimi, açılış adresi `ApplicationDelegateProxy.lastURL`) otomatik yakalanır; `autoCaptureDeepLinks: false` ile kapatılır. Kısa link yolu için `handleShortLink(url)`.
- Web yedeği: kurulum, mağaza, push belirteci ve ertelenmiş derin bağlantı tarayıcıda yoktur; `not_supported` ya da `null` döner.

## Geliştirme

```bash
cd sdks/capacitor
npm run build             # @capacitor/core ve @feralin/web kurulu olmalı
node --test test/*.test.mjs
```

## English

Capacitor plugin for Feralin. `Feralin` (TypeScript) validates input; Android calls the Feralin Android core (`FeralinPlugin.java`, local Maven repo produced by `scripts/vendor.mjs`), iOS calls the Feralin Swift core (`FeralinPlugin.swift` + shared `FeralinBridge.swift`), and the browser falls back to `@feralin/web`.

Verification status: 14 JS/TS unit tests pass (mocked native bridge, mocked and real `@feralin/web` build) and the type check passes against `@capacitor/core` 8.6.0. The Android plugin class compiles with `javac` against `@capacitor/android` 8.6.0 sources and the real Feralin AAR; it has **not** been built with Gradle inside a Capacitor app or run on a device. The iOS plugin is **not compiled** (needs a Mac and Xcode); the shared bridge compiles and passes XCTest on Linux. Event receipt from a real app is **not verified**. Not published to npm.
