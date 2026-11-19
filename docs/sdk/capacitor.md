<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Capacitor: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/capacitor/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript, Java, Swift |
| Paket | `@feralin/capacitor` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | UNIT_TESTED |
| Kaynak dizin | `sdks/capacitor` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: npm yayını site sahibinin açık onayını ister) |
| Derleme | `npm --prefix sdks/capacitor run build` |
| Test | `npm --prefix sdks/capacitor test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
cd sdks/capacitor
node scripts/vendor.mjs                      # Swift çekirdeği → ios/Sources/Feralin, Android çekirdeği → android/maven-repo
npm install --no-save @capacitor/core@8 @feralin/web@0.1.0 && npm run build   # dist/esm
cd /path/to/your-capacitor-app
npm install /path/to/Feralin.com/sdks/capacitor
npx cap sync
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | PARTIAL (track, screen; TS birim testli, Android eklentisi javac ile derlendi, iOS ortak köprüsü Linux XCTest ile sınandı; cihazda koşmadı) |
| batch | PARTIAL (yerel çekirdeklerin kalıcı kuyruğu, web'de @feralin/web localStorage kuyruğu; cihazda koşmadı) |
| consent | PARTIAL (setConsent, optOut; iOS'ta izin verilmezse analitik kapalı sayılır; cihazda koşmadı) |
| identity | PARTIAL (identify, reset, group, setUserProperties, setGlobalProperties, installIdentifier; cihazda koşmadı) |
| attribution | PARTIAL (Android ilk açılışı otomatik, iOS trackFirstOpen kurulum başına bir kez ve install_store; web not_supported; cihazda koşmadı) |
| deeplink | PARTIAL (Android handleOnNewIntent ve iOS capacitorOpenUniversalLink otomatik, handleShortLink, consumeDeferredDeepLink; cihazda koşmadı) |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda) |
| error | UNSUPPORTED |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PARTIAL | TypeScript yüzü, web yedeği (@feralin/web), Android Java eklentisi, iOS CAPPlugin yazıldı. iOS eklentisi derlenmedi: Mac ve Xcode gerekir (BLOCKED_EXTERNAL). |
| build | PARTIAL | 19 Kasım 2026: tsc (skipLibCheck false) @capacitor/core 8.6.0 ve @feralin/web bildirimlerine karşı dist/esm üretti; @capacitor/core depo dışı geçici dizinden çözüldü, depoda node_modules yok (npm run build için @capacitor/core kurulmalı). FeralinPlugin.java javac ile @capacitor/android 8.6.0 kaynağına, Android 36 android.jar ve gerçek Feralin AAR'ına karşı derlendi; scripts/vendor.mjs çekirdeği android/maven-repo'ya yazdı. Gradle ile Capacitor uygulamasında derlenmedi. |
| test | PASS | node --test 14/14 (sahte yerel eklenti, sahte ve gerçek @feralin/web derlemesiyle web yedeği; yöntem adları Java, Swift ve web yedeğinde, FeralinConfig alan sırası Types.kt ile karşılaştırılır); ortak iOS köprüsü sdks/cordova ile aynı dosya, Linux'ta 7/7 XCTest. |
| registry | BLOCKED_EXTERNAL | Yayın yapılmadı; site sahibinin onayı gerekir. |
| clean_install | NOT_RUN | Boş Capacitor uygulamasına npm install ve cap sync denenmedi. |
| event_receipt | NOT_RUN | Uygulama içinde, emülatörde ve iPhone'da gerçek toplayıcıyla denenmedi. Web yedeği gerçek @feralin/web derlemesiyle olay üretti (ağ çağrısı yapılmadı). |
| documentation | PASS | docs/sdk/capacitor.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
