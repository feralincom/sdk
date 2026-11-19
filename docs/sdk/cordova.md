<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Cordova: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/cordova/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | JavaScript, Java, Swift |
| Paket | `cordova-plugin-feralin` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | UNIT_TESTED |
| Kaynak dizin | `sdks/cordova` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: npm yayını site sahibinin açık onayını ister; paket adı kapsamsız (cordova-plugin-feralin), çünkü cordova-ios Swift Package ürün adını eklenti kimliğinden üretir) |
| Derleme | `node sdks/cordova/scripts/vendor.mjs` |
| Test | `npm --prefix sdks/cordova test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
cd sdks/cordova
node scripts/vendor.mjs          # Swift çekirdeğini kopyalar, Android AAR'ını derleyip kopyalar
cd /path/to/your-cordova-app
cordova plugin add /path/to/Feralin.com/sdks/cordova
```

## İlk kullanım

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

```js
Feralin.setPushToken(token);                 // Android: FCM kayıt belirteci; iOS: APNs belirtecinin onaltılı yazımı
if (Feralin.isUninstallCheck(message.data)) return; // Feralin'in sessiz bildirimi: kullanıcıya göstermeyin
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | PARTIAL (track, screen; JS birim testli, Android köprüsü javac ile derlendi, iOS ortak köprüsü Linux XCTest ile sınandı; cihazda koşmadı) |
| batch | PARTIAL (yerel çekirdeklerin kalıcı kuyruğu; JS tarafında kuyruk yok; cihazda koşmadı) |
| consent | PARTIAL (setConsent, optOut; iOS'ta izin verilmezse analitik kapalı sayılır; cihazda koşmadı) |
| identity | PARTIAL (identify, reset, group, setUserProperties, setGlobalProperties, installIdentifier; cihazda koşmadı) |
| attribution | PARTIAL (Android çekirdeği ilk açılışı Play referrer ve kurulum mağazasıyla otomatik üretir; iOS trackFirstOpen kurulum başına bir kez, iOS 17.4+ install_store; cihazda koşmadı) |
| deeplink | PARTIAL (Android onNewIntent otomatik, handleShortLink, consumeDeferredDeepLink; iOS handleUniversalLink elle, ertelenmiş bağlantı attribution yapılandırmasıyla; cihazda koşmadı) |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı, Web ve Android ile aynı kurallar; verified yalnız sunucuda) |
| error | UNSUPPORTED |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PARTIAL | JS yüzü, tip bildirimleri, Android Java köprüsü, iOS Swift Package köprüsü yazıldı. iOS Cordova sarmalayıcısı (FeralinCordovaPlugin.swift) derlenmedi: Mac ve Xcode gerekir (BLOCKED_EXTERNAL). |
| build | PARTIAL | 19 Kasım 2026: scripts/vendor.mjs Android çekirdeğini derleyip AAR'ı ve Swift çekirdeğini kopyaladı; FeralinPlugin.java javac ile cordova-android 14.0.1 çerçeve kaynağına, Android 36 android.jar ve gerçek Feralin AAR'ına karşı derlendi; ortak iOS köprüsü (FeralinBridge.swift) Swift 6.4.2 ile Linux'ta derlendi. Gerçek Cordova uygulamasında Gradle ve Xcode derlemesi yapılmadı. |
| test | PASS | node --test 18/18 (sahte cordova/exec; eylem adları Java ve Swift köprüsüyle, FeralinConfig alan sırası Types.kt ile karşılaştırılır); tsc --noEmit geçti; scripts/check-ios-bridge.sh 7/7 XCTest (Linux, Swift 6.4.2). Android ve iOS köprüleri cihazda sınanmadı. |
| registry | BLOCKED_EXTERNAL | Yayın yapılmadı; site sahibinin onayı gerekir. |
| clean_install | NOT_RUN | cordova plugin add ile boş Cordova uygulamasına kurulum denenmedi. |
| event_receipt | NOT_RUN | Emülatör, iPhone ve gerçek toplayıcı ile denenmedi. Android'de olaylar platform=android, sdk=feralin-android gider (çekirdek SdkWrapper yalnız react_native kabul eder). |
| documentation | PASS | docs/sdk/cordova.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
