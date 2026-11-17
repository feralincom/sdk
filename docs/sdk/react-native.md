<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# React Native: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/react-native/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript, Kotlin |
| Paket | `@feralin/react-native` |
| Sürüm | 0.2.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/react-native` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: @feralin npm organizasyonu, 2FA; Android çekirdeği için Maven Central) |
| Derleme | `npm --prefix sdks/react-native run build` |
| Test | `npm --prefix sdks/react-native test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
cd sdks/react-native
npm pack          # Android SDK ve JDK 17 gerekir; çekirdek derlenir
npm install /yol/feralin-react-native-0.1.0.tgz
```

## İlk kullanım

```ts
import Feralin from "@feralin/react-native";

await Feralin.initialize({
  projectKey: "pk_live_...", // yalnız x-feralin-project-key başlığında taşınır
  collectUrl: "https://collect.example.com",
  consent: kayitliKarar, // karar yoksa vermeyin
});

Feralin.setConsent({ analytics: true, advertising: false });
const eventId = await Feralin.track("purchase", { amount: 10.5 });
await Feralin.screen("home");
Feralin.identify("kullanici_42"); // PII vermeyin
const result = await Feralin.flush(); // { sent, accepted, rejected, status, batchId }
Feralin.reset(); // çıkış
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız; yalnız Android; oyun olayı yöntemleri trackLevelStart/Complete/Fail, trackEconomySource/Sink, trackRewardedAdShown/Complete, trackIapOfferShown/Initiated JS birim testli, emülatörde ayrıca koşulmadı) |
| batch | PARTIAL (Android kalıcı kuyruk, olay gövdeleri Keystore ile şifreli (#10 çekirdeği, birim testli; cihazda sınanmadı); JS tarafında kuyruk yok; iOS yok) |
| consent | SUPPORTED (yayınsız; yalnız Android) |
| identity | PARTIAL (identify, reset, group, setUserProperties, yalnız Android; group ve setUserProperties `fr_group` ve `fr_user_properties` olayıdır, toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar; birim testli) |
| attribution | PARTIAL (#10 çekirdeği, gerçek Play tıklamasıyla sınanmadı; iOS `BLOCKED_EXTERNAL`; `bindInstall` TS yüzü yazıldı, iOS yerel modülü yokken `unsupported`) |
| deeplink | PARTIAL (Android App Links ve ertelenmiş yol teslimi, gerçek Play kurulumuyla sınanmadı; iOS ertelenmiş `not_supported`) |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı, Android ve Flutter ile aynı kurallar, yalnız Android; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; trackAdRevenue → fr_ad_revenue (revenue_micros, ayrı gelir sınıfı: istemci beyanı, sunucuda ESTIMATED, reklam ağı mutabakatı BLOCKED_EXTERNAL), JS birim testli) |
| error | PARTIAL (captureError ve captureUncaughtErrors → fr_error: ErrorUtils genel işleyicisi ve işlenmemiş Promise reddi, yığın çerçeve parmak izi, örnekleme ve sınır, JS birim testli; emülatörde koşulmadı; yerel çökme ve ANR yok, sembolleştirme yok, ölümcül hatada olay kuyruğa yetişmeyebilir) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PARTIAL | Android köprüsü ve JS yüzeyi yazıldı; iOS BLOCKED_EXTERNAL, macOS ve Xcode gerekir. |
| build | PASS | Köprü assembleRelease; iOS derlenemez. |
| test | PASS | JS birim testi ve Kotlin eşleme testi. |
| registry | BLOCKED_EXTERNAL | @feralin npm organizasyonu yok. |
| clean_install | PASS | npm pack çıktısı temiz React Native 0.87.1 projesine kuruldu, release APK derlendi. |
| event_receipt | PASS | Emülatörde gerçek JS → köprü → çekirdek → collect: izin, reklam izni, opt-out, çevrimdışı flush. Gerçek cihaz SDK-R07 BLOCKED_EXTERNAL. |
| documentation | PASS | docs/sdk/react-native.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
