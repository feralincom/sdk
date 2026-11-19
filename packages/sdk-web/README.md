# @feralin/web — Feralin Web SDK (UTP v1)

**Durum:** npm'de yayımlandı: `@feralin/web@0.1.0` (17 Kasım 2026, `@feralin` organizasyonu); sürüm ve özet registry'den geri okundu. Yayın yaşam döngüsü: `docs/sdk/capability-matrix.md`, `feralin_proje_v21.md` §42.

## Kurulum
npm'den kurulur (`FERALIN_E2E_FROM_REGISTRY=1 node scripts/sdk-e2e/run.mjs web` aynı kurulumu boş dizinde npmjs.org'dan sınar: ESM ve CommonJS içe aktarma, gerçek toplayıcıya olay):
```bash
npm install @feralin/web
```
Derleme aracı olmayan sitelerde betik Feralin'in kendi adresinden yüklenir: `https://feralin.com/sdk/feralin.iife.js` (genel `feralin` nesnesi).

## Kullanım
```html
<script src="https://feralin.com/sdk/feralin.iife.js" defer></script>
<script>
  window.addEventListener("load", () => {
    feralin.initialize({
      projectKey: "pk_live_…",              // yalnız public anahtar
      collectUrl: "https://feralin.com/collect",
      consent: { analytics: true, advertising: false }, // consent yoksa olay üretilmez
    });
  });
</script>
```
```ts
import { initialize, track } from "@feralin/web";
initialize({ projectKey: "pk_live_…", collectUrl: "https://feralin.com/collect", consent: { analytics: true } });
track("signup_completed", { plan: "growth" });
```

## API
`initialize(options)`, `page(props?)`, `track(name, props?)`, `identify(userId)`, `group(groupId, traits?)`, `setUserProperties(props)`, `setGlobalProperties(props)`, `clearGlobalProperties()`, `setConsent(consent)`, `optOut()`, `reset()`, `flush()`, `getStatus()`.

Kimlik yöntemleri (UTP §8.2): `group(groupId, traits?)` → `fr_group`, `setUserProperties(props)` → `fr_user_properties`, `setGlobalProperties(props)` ve `clearGlobalProperties()`. Anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, çağrı başına ve global haritada en çok 50; değer yalnız dizge (≤256 karakter, e-posta biçiminde değil), sonlu sayı ya da mantıksal. Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) ve doğrulama alanları (`verified`, `receipt` vb.) istemcide düşer. Global özellikler `fr_` dışındaki her olaya eklenir, olayın kendi özelliği aynı anahtarda ezer, `null` anahtarı siler, `reset()` temizler. Grup kimliği 1-128 karakter, `@` ve kontrol karakteri içermez. Toplayıcı yalnız projenin kullanıcı özelliği izin listesindeki anahtarları saklar; liste boşsa otomatik kip: kişisel veriye benzemeyen her anahtar saklanır. Global özellikler yalnız bellektedir, depoya yazılmaz.

## Sayfada görünür süre (`fr_page_engagement`)
Çekirdek SDK her `page_view` için sekmenin gerçekten görünür olduğu süreyi (`document.visibilityState === "visible"`) biriktirir ve `fr_page_engagement` {`visible_ms`} olayı olarak gönderir; arka plandaki sekmenin süresi sayılmaz, oturumun son sayfası da ölçülür. Olay üç noktada kuyruğa girer: sekme gizlenince (`visibilitychange`), sayfa kapanırken (`pagehide`; ikisinde de sayfa kapanışı gönderiminden önce, aynı istekle çıkar) ve sonraki `page_view`'dan hemen önce (tek sayfalı uygulamada rota değişimi ya da elle `page()`). Olayın `context.page_url`, `context.page_title` ve `session_id` değerleri ölçülen `page_view` anındakilerdir, gönderim anındakiler değil; olay oturumu uzatmaz. `visible_ms` son gönderimden beri geçen görünür süredir (tam milisaniye, 1 000-3 600 000; üstü bir saate kırpılır): bir sayfa görüntülemesi için birden çok olay gelebilir, sunucu oturum ve sayfa başına toplar. 1 saniyenin altındaki birikim gönderilmez, aynı sayfa görüntülemesinin sonraki gönderimine devreder. İzin kapısı diğer olaylarla aynıdır: `consent.analytics` yoksa olay üretilmez; izin geri çekilince, `reset()` ve `destroy()` ile birikim gönderilmeden silinir. Global özellikler ve `utm_*` bu olaya eklenmez. Kapatmak için `initialize({ ..., pageEngagement: false })` (varsayılan `true`).

## Replay/heatmap modülü (`@feralin/web/replay`, `dist/feralin-replay.iife.js`)
Ayrı betiktir; çekirdek bütçesine girmez ve varsayılan yüklenmez. **DOM kaydı, metin, form değeri ve oturum oynatma yoktur**: yalnız üç etkileşim olayı gider (`fr_replay_click` {sel, x, y, vp}, `fr_replay_scroll` {depth, vp}, `fr_replay_view` {sel, vp}; `view` yalnız `data-fr-view` işaretli bölümlerde). Seçici maskelidir ve maskeleme kapatılamaz: etiket adı, güvenli `id` ve `:nth-of-type`; sınıf, öznitelik değeri, `href`, `value` ve metin hiç okunmaz; `data-fr-mask` taşıyan ata zinciri `[masked]` ile keser; form öğeleri yalnız `input[type=…]` yazılır. Koordinatlar görünüm alanına göre yüzdedir, görünüm alanı sınıf olarak gider (`xs|sm|md|lg|xl`), piksel gönderilmez.
İzin kapısı çifttir: `consent.analytics` ve `consent.session_replay === true`. İzin yokken DOM okunmaz; geri çekilince modül aynı anda susar. Toplayıcı aynı kuralları sunucuda uygular (`replay_consent_denied`, `replay_payload_invalid`).
```ts
import { initialize } from "@feralin/web";
import { startReplay } from "@feralin/web/replay";
const client = initialize({ projectKey: "pk_live_…", collectUrl: "https://feralin.com/collect", consent: { analytics: true, session_replay: true } });
const replay = startReplay({ client }); // replay.stop() ile kaldırılır
```

## Otomatik olay modülü (`@feralin/web/auto`, `dist/feralin-auto.iife.js`)
Ayrı betiktir; çekirdek bütçesine girmez. Her davranış ayrı açılıp kapanır, olaylar çekirdek örnekten geçer: **`consent.analytics` yokken hiçbir olay üretilmez**, izin geri çekilince modül aynı anda susar. Sorgu dizgisi ve parça hiçbir olaya girmez.

| Seçenek | Varsayılan | Olay |
|---|---|---|
| `spa` | açık | Tek sayfalı uygulamada **yol** değişince `page_view` (History API: `pushState`, `replaceState`, `popstate`); önceki sayfa yönlendiren olarak gider (`setReferrer`). Yalnız sorgu ya da parça değişimi yeni sayfa sayılmaz |
| `outbound` | açık | `fr_outbound_click` `{link_host}`: başka alan adına giden bağlantı (yalnız alan adı) |
| `downloads` | açık | `fr_file_download` `{file_extension, file_name}`: izinli uzantılı bağlantı (`true` varsayılan liste, dizi verilirse yalnız o uzantılar, `false` kapalı) |
| `notFound` | açık | `fr_not_found`: `<meta name="feralin:status" content="404">` ya da `prerender-status-code`, yoksa başlıkta tek başına "404"; `() => boolean` verilirse onun sonucu |
| `siteSearch` | **kapalı** | `fr_site_search` `{search_term, search_param}`: arama metni kişisel veri taşıyabildiği için varsayılan kapalıdır; `true` (`q`, `s`, `search`, `query`, `keyword`) ya da parametre listesi; metin 100 karaktere kırpılır |

```ts
import { initialize } from "@feralin/web";
import { startAutoEvents } from "@feralin/web/auto";
const client = initialize({ projectKey: "pk_live_…", collectUrl: "https://feralin.com/collect", consent: { analytics: true } });
const auto = startAutoEvents({ client, siteSearch: ["q"], downloads: ["pdf", "zip"] }); // auto.stop() ile kaldırılır
```
Dönüşüm hedefleri panelden tanımlanır ve sunucuda mevcut olaylardan (olay adı ya da sayfa yolu deseni) hesaplanır; SDK'da ayrı bir ayar gerekmez.

## Bayrak modülü (`@feralin/web/flags`, `dist/feralin-flags.iife.js`)
`POST /v1/flags/evaluate` ucunu herkese açık proje anahtarıyla çağırır; özne çekirdek SDK'nın kimliğidir (varsa `user_id`, yoksa `anonymous_id`), tarayıcı özelliği karıştırılmaz (parmak izi yok). Atama sunucuda belirlenimci özetle hesaplanır, istemci yalnız okur; sonuç bellek içinde 60 sn tutulur, depoya yazılmaz. Bir bayrak ilk okunduğunda `fr_flag_exposure` {flag_key, variant, enabled} olayı bir kez gönderilir (analitik izni yoksa hiç gönderilmez). Yüklenmemiş ya da bilinmeyen anahtar `fallback` döner.
```ts
import { FeralinFlags } from "@feralin/web/flags";
const flags = new FeralinFlags({ client, apiUrl: "https://feralin.com/api", projectKey: "pk_live_…", keys: ["new_checkout"] });
await flags.load();
if (flags.isEnabled("new_checkout")) { /* varyant: flags.variant("new_checkout") */ }
```

## Hata yakalama modülü (`@feralin/web/errors`, `dist/feralin-errors.iife.js`)
`window` `error` ve `unhandledrejection` olaylarını dinler; her hata `fr_error` olayına çevrilir (çekirdek SDK'nın izin kapısından geçer). Giden alanlar: hata sınıfı adı (`error_type`), temizlenmiş kısa mesaj (e-posta, URL, uzun sayı ve belirteç çıkarılır, 200 karakter), normalize yığın çerçevelerinin özeti `fingerprint` (aynı hata kod kaysa da aynı özeti üretir), en üst çerçeve `top_frame` (`işlev@dosya`, satır ve yol yok) ve isteğe bağlı `app_version`. **Ham yığın izi, URL ve sayfa içeriği gitmez.** Örnekleme (`sampleRate`) ve sınır vardır: sayfa yüklemesi başına en çok 20 olay, aynı parmak izi için en çok 3. Sembolleştirme için en üst beş çerçevenin konumu `frames` olarak gider: yalnız üretilmiş dosyanın taban adı (`app.3f9a1b2c.js`, dizin, alan adı ve sorgu yok), satır, sütun ve işlev adı; `sourcePositions: false` kapatır. Panelden ya da `symbols:write` yetkili API anahtarıyla yüklenen kaynak haritası bu konumu okuma anında kaynak dosya ve satıra çözer (`GET /v1/projects/{id}/crashes/{fingerprint}/frames`); harita `appVersion` ile aynı sürümle yüklenirse önceliklidir. Toplayıcı mesajı sunucuda ayrıca temizler ve izin listesi dışı alanı düşürür.
```ts
import { initialize } from "@feralin/web";
import { captureErrors } from "@feralin/web/errors";
const client = initialize({ projectKey: "pk_live_…", collectUrl: "https://feralin.com/collect", consent: { analytics: true } });
const errors = captureErrors({ client, appVersion: "1.4.2", sampleRate: 1 });
try { riskyCall(); } catch (e) { errors.capture(e); }   // elle bildirim: handled=true
```

## Core Web Vitals modülü (`@feralin/web/vitals`, `dist/feralin-vitals.iife.js`)
Tarayıcının kendi `PerformanceObserver` girdilerinden LCP, INP, CLS ve TTFB ölçer; her ölçüt sayfa yüklemesi başına en çok bir kez `fr_web_vital` {metric, value, rating, navigation_type} olayı olarak gider (çekirdek SDK'nın izin kapısından geçer: `consent.analytics` yoksa olay üretilmez). TTFB gezinme yanıtı gelince, LCP ilk kullanıcı girdisinde ya da sayfa gizlenince, CLS (en büyük oturum penceresi) ve INP (her 50 etkileşimde bir aykırı atlanır) sayfa gizlenince bildirilir. Dinleyiciler yakalama evresindedir: ölçüt olayı çekirdeğin sayfa kapanışı gönderiminden önce kuyruğa girer. **Öğe seçicisi, URL sorgusu, ekran ölçüsü ya da cihaz özelliği gitmez; parmak izi üretilmez.** Tarayıcı bir girdi türünü desteklemiyorsa o ölçüt gönderilmez, tahmin edilmez. Değerler süreler için tam milisaniye, CLS için dört ondalıktır; sınır dışı değer (süre > 60 sn, CLS > 10) gönderilmez. Panel (UI-066) ölçüt başına p75'i cihaz sınıfı ve sayfa yoluna göre gösterir; 10 tekil ziyaretçiden az hücre gizlidir.
```ts
import { initialize } from "@feralin/web";
import { captureVitals } from "@feralin/web/vitals";
const client = initialize({ projectKey: "pk_live_…", collectUrl: "https://feralin.com/collect", consent: { analytics: true } });
captureVitals({ client, sampleRate: 1 });   // sampleRate: sayfa yüklemesi başına örnekleme (0..1)
```

## Garantiler
- `event_id` ULID; sunucu dedup ve `Idempotency-Key` ile at-least-once + idempotent etki. Anahtar batch içeriğini yansıtır: `<tüm event_id'lerin FNV-1a 64 özeti>-<adet>`.
- 202 → kuyruktan düşer; 5xx/ağ → kuyrukta kalır ve aynı idempotency anahtarıyla tekrar; 4xx (429 hariç) → atılır.
- `analytics` izni yoksa olay üretilmez ve gönderilmez. İzin reddedilince (`consent: { analytics: false }`, `setConsent`, `optOut`) kuyruk silinir; `consent` hiç verilmediyse önceki oturumdan kalan kuyruk izin gelene kadar bekletilir.
- `projectKey` kırpılır ve `pk_` ile başlamalıdır; `sk_` ve başka önekler kurulumda hata verir.
- `initialize` yeniden çağrılınca eski örnek yok edilir: dinleyicileri kalkar, olay üretmez, göndermez, depoya yazmaz. Kuyruk silinmez; aynı depoyu kullanan yeni örnek okur. Depolama engelliyse (bellek içi yedek) depo örneğe özeldir ve eski örnekte bekleyen olaylar kaybolur.
- `fr_aid` izin verilmeden depoya yazılmaz; kimlik bellekte kalır, izin verilince yazılır, izin geri çekilince silinir ve yenilenir: izin yeniden verilse de eski anonim kimlik ve oturum geri gelmez.
- `fr_sid` oturum kimliğini ve son etkinlik anını tutar; aynı kurala uyar (izin yoksa yazılmaz, izin geri çekilince silinir). Oturum sayfa yüklemeleri ve sekmeler arasında sürer; 30 dakika hareketsizlikten sonraki ilk olay yeni oturum başlatır. İzin yokken oturum yalnız o sayfa örneğinin belleğindedir.
- `autoTrack` açıkken izin sonradan gelirse o sayfanın `page_view` olayı `setConsent` ile bir kez üretilir.
- `page_url` scheme+host+path, `referrer` yalnız origin gönderilir. Sorgu ve parça gönderilmez; yalnız `utm_source/medium/campaign/term/content` `properties.utm_*` olarak taşınır (açıkça verilen özellik ezilmez).
- Parmak izi, canvas/font taraması, IP toplama yok. `properties` anahtarları allowlist deseniyle filtrelenir.
- IIFE gzip bütçesi 8 KB (build'de doğrulanır).

## Smart Script (web açılış sayfası)

`/sdk/feralin-smart.iife.js` betiği sayfadaki App Store, Google Play, AppGallery ve Galaxy Store bağlantılarını Feralin kısa linkine çevirir
ve sayfanın UTM ile reklam tıklama kimliklerini (gclid, fbclid, ttclid…) linke ekler. Linkin kendi parametresi önceliklidir.

```html
<script src="https://feralin.com/sdk/feralin-smart.iife.js" defer></script>
<script>
  window.addEventListener("DOMContentLoaded", function () {
    window.feralinSmart.apply({ link: "https://feralin.com/l/KOD" });
  });
</script>
```

Başka öğeleri çevirmek için `data-feralin-smart` özniteliği ya da `selector` seçeneği kullanılır. `referrerAsSource: true` verilirse UTM
yokken yönlendirenin alan adı `utm_source` olur. Çerez yazılmaz; parametreler yalnız ziyaret boyunca `sessionStorage`'da tutulur.
ESM kullanımı: `import { applySmartScript } from "@feralin/web/smart"`.
