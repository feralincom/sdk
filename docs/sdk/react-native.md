<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# React Native: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/react-native/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript, Kotlin |
| Paket | `@feralin/react-native` |
| Sürüm | 0.2.0 |
| Yaşam döngüsü | INSTALL_VERIFIED |
| Kaynak dizin | `sdks/react-native` |
| Registry | npm: **PUBLISHED** (sonraki adım: her paket için npm trusted publishing (OIDC); npm 2FA'yı atlayan anahtarla doğrudan yayını Ocak 2027'de kapatıyor; Android çekirdeği Maven Central'da ayrıca yayımlanmadı (npm paketinde android/maven-repo ile gelir)) |
| Derleme | `npm --prefix sdks/react-native run build` |
| Test | `npm --prefix sdks/react-native test` |

## Kurulum

```bash
npm install @feralin/react-native
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
| event | SUPPORTED (yalnız Android; oyun olayı yöntemleri trackLevelStart/Complete/Fail, trackEconomySource/Sink, trackRewardedAdShown/Complete, trackIapOfferShown/Initiated JS birim testli, emülatörde ayrıca koşulmadı) |
| batch | PARTIAL (Android kalıcı kuyruk, olay gövdeleri Keystore ile şifreli (#10 çekirdeği, birim testli; cihazda sınanmadı); JS tarafında kuyruk yok; iOS yok) |
| consent | SUPPORTED (yalnız Android) |
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
| registry | PASS | npm'de yayımlandı: @feralin/react-native@0.2.0 (17 Kasım 2026, git b1a7d127, org @feralin; ilk yayın site sahibinin tek onayıyla, docs/sdk/npm-yayin-adimlari.md B yolu; RELEASE_CANDIDATE dört göz koşulu bu yayında aranmadı). Registry'den geri okuma: latest 0.2.0, dist.integrity sha512-om4n5YvDmcdZ… yerel kuru koşu paketinin özetiyle birebir aynı, sahip org @feralin. npm ilk yayında 2 dosyalık 0.0.0-stage yer tutucu sürümünü de oluşturdu; Feralin yayını değildir. |
| clean_install | PASS | npm pack çıktısı temiz React Native 0.87.1 projesine kuruldu, release APK derlendi. Registry'den temiz kurulum: FERALIN_E2E_FROM_REGISTRY=1 node sdks/react-native/scripts/e2e-emulator.mjs (17 Kasım 2026): @react-native-community/cli init ile boş React Native 0.87.1 projesine @feralin/react-native@0.2.0 npmjs.org'dan kuruldu (resolved https://registry.npmjs.org/@feralin/react-native/-/react-native-0.2.0.tgz, kilit dosyasındaki sürüm ve özet registry'deki dist.integrity ile aynı), pakette gelen android/maven-repo ile release APK (x86_64) derlendi. |
| event_receipt | PASS | Emülatörde gerçek JS → köprü → çekirdek → collect: izin, reklam izni, opt-out, çevrimdışı flush. Gerçek cihaz SDK-R07 BLOCKED_EXTERNAL. Registry'den kurulan @feralin/react-native@0.2.0 ile (17 Kasım 2026, API 36 emülatör, SDK_E2E_CLICKHOUSE_URL ile): izinsiz ve opt-out sonrası olay yok, reklam izni varken 202, ağ kesikken kuyrukta 1 olay, ağ gelince boşaldı; outbox'ta 8 satır, collect worker sonrası ClickHouse'ta 3 olay tam bir kez (events FINAL, uniqExact 3; platform react_native, sdk_name @feralin/react-native 0.2.0, provenance REAL_VERIFIED). |
| documentation | PASS | docs/sdk/react-native.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
