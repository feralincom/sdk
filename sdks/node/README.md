# @feralin/node

Sunucu tarafından `POST /v1/batch` ucuna UTP v1 olayı gönderen Node.js SDK'sı. TypeScript ile yazıldı, çalışma zamanı bağımlılığı yoktur. ESM ve CommonJS desteklenir. Node 20 ve üstü.

## Durum

| Konu | Durum |
|---|---|
| Kod, birim testleri, `npm pack` | Geçiyor |
| Gerçek `services/collect` + PostgreSQL, temiz kurulum | `scripts/sdk-e2e/run.mjs node` ile doğrulandı |
| npm yayını | npm'de yayımlandı: `@feralin/node@0.1.0` (17 Kasım 2026, `@feralin` organizasyonu); sürüm ve özet registry'den geri okundu |
| npmjs.org'dan temiz kurulum + gerçek `services/collect` | `FERALIN_E2E_FROM_REGISTRY=1 scripts/sdk-e2e/run.mjs node` ile doğrulandı (outbox ve ClickHouse) |

## Kurulum

```bash
npm install @feralin/node
```

## Kullanım

```ts
import { FeralinClient } from "@feralin/node";

const feralin = new FeralinClient({
  projectKey: process.env.FERALIN_PROJECT_KEY!, // pk_… anahtarı; kaynak koda yazmayın
  collectUrl: "https://collect.example.com",
});

// İzin kararı son kullanıcınındır; uygulamadan olay başına geçirilir.
feralin.track(
  "order_completed",
  { order_id: "ord_1", fr_click: clickId },
  { userId: "user_42", consent: { analytics: true, advertising: reklamIzni } },
);

// Kimlik yöntemleri (UTP §8.2): kimlik olay başına verilir, global özellikler istemci örneğinindir.
feralin.setUserProperties({ plan: "pro", tier: 2 }, { userId: "user_42", consent: { analytics: true } });
feralin.group("acme-team", { plan: "team" }, { userId: "user_42", consent: { analytics: true } });
feralin.setGlobalProperties({ app_release: "2026.11" });

// Yakalanan hata (`fr_error`): ham yığın izi gitmez; sınır saatte 20 olay, aynı hata için 3.
try {
  await siparisiKaydet();
} catch (error) {
  feralin.captureError(error, { userId: "user_42", consent: { analytics: true } });
}

// Kapanışta kalanı gönderin.
process.once("SIGTERM", () => void feralin.close());
```

## Kurallar

| Konu | Davranış |
|---|---|
| İzin | Varsayılan `analytics=false`. İzin yoksa `track` `null` döner, olay üretilmez, istek yapılmaz |
| Açık ret | `setConsent({ analytics: false })` veya `optOut()` kuyruğu siler, olay bazlı izin de geçersiz olur |
| `fr_click` | Yalnız `advertising === true` iken gönderilir, aksi halde çıkarılır |
| Anahtar | Yalnız `x-feralin-project-key` başlığında. `sk_` kurucuda reddedilir. Log ve durum çıktısında yoktur |
| Idempotency | Sıralı tüm `event_id` değerlerinin FNV-1a 64 özeti + sayı; Web, .NET, Android ile aynı |
| Yeniden deneme | `202` ve kalıcı `4xx` kuyruktan siler. `429`, `5xx`, ağ hatası aynı içerik ve anahtarla denenir. Üstel 1 sn ile 30 sn, yarım jitter, `Retry-After` uyumlu |
| Hata | Yapılandırma hatası kurucuda fırlar (Web SDK ile aynı). Çalışma zamanında hiçbir metot fırlatmaz; `flush` sonucu `FlushResult` içindedir |
| URL | `page_url` sorgusuz, `referrer` yalnız origin. `utm_*` özelliklere taşınır |
| Hata | `captureError` → `fr_error`: `error_type` (≤64), temizlenmiş `message` (≤200), `fingerprint` (FNV-1a 64; tür + en üst beş `işlev@dosya`), `top_frame`, `frame_count`, `frames` (en çok 5; dosya taban adı, satır, sütun, işlev), `handled`, `fatal`, `origin`, `errors.appVersion` verilirse `app_version`. Node iç çerçeveleri uygulama çerçevesi varken atlanır. `errors.sourcePositions: false` konumları kapatır. Sınır: `errors.maxEvents` (20), `errors.maxPerFingerprint` (3), `errors.windowMs` (1 saat), `errors.sampleRate` (1) |
| Kurulum kodu | `installCode` biçime uyarsa (`^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$`) ilk uygun olaya `fr_install_code` olarak bir kez eklenir. Masaüstü ve tek kullanıcılı süreç içindir |
| Kuyruk | Bellek içi, en çok 1000 olay, aşılınca en eski atılır. `storageDirectory` verilmezse süreç ölünce kaybolur. Tek olay 900 KB ile sınırlıdır |
| Kalıcı kuyruk | İsteğe bağlı `storageDirectory` (yayın bekliyor, aşağıya bakın) |
| Kimlik | Kimlik yöntemleri (UTP §8.2): `group(groupId, traits?)` → `fr_group`, `setUserProperties(props)` → `fr_user_properties`, `setGlobalProperties(props)` ve `clearGlobalProperties()`. Anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, çağrı başına ve global haritada en çok 50; değer yalnız dizge (≤256 karakter, e-posta biçiminde değil), sonlu sayı ya da mantıksal. Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) ve doğrulama alanları (`verified`, `receipt` vb.) istemcide düşer. Global özellikler `fr_` dışındaki her olaya eklenir, olayın kendi özelliği aynı anahtarda ezer, `null` anahtarı siler, `reset()` temizler. Grup kimliği 1-128 karakter, `@` ve kontrol karakteri içermez. Toplayıcı yalnız projenin kullanıcı özelliği izin listesindeki anahtarları saklar (liste boşsa hiçbiri; olay yine sayılır). Düşen anahtarların adı ve nedeni `logger.warn` ile yazılır, değeri yazılmaz. İstemci istekler arasında paylaşılıyorsa kullanıcıya özgü değeri global özelliğe koymayın |

## Kalıcı kuyruk (`storageDirectory`)

> Yayın bekliyor: depoda var, npm'deki `@feralin/node@0.1.0` içinde yok. Sonraki sürümle yayımlanacak.

```ts
const feralin = new FeralinClient({
  projectKey: process.env.FERALIN_PROJECT_KEY!,
  collectUrl: "https://collect.feralin.com",
  storageDirectory: "/var/lib/uygulama/feralin-queue",
  storageMaxBytes: 10 * 1024 * 1024, // varsayılan 10 MiB
  storageMaxAgeMs: 7 * 24 * 60 * 60 * 1000, // varsayılan 7 gün, en çok 90 gün
});
```

| Konu | Davranış |
|---|---|
| Çökme | Kuyruk her işlemde dizindeki günlük dosyasına eklenir. Süreç çökerse ya da `close` gönderemeden çıkarsa olaylar sonraki açılışta okunur ve gönderilir |
| Idempotency | Gönderime giren batch'in bileşimi de yazılır: yanıtı kaybolan batch çöküşten sonra aynı olaylarla ve aynı `Idempotency-Key` ile gider, toplayıcı ikinci outbox satırı yazmaz. Kabul edilen ya da kalıcı reddedilen olay günlükten çıkar, yeniden gitmez |
| Süreç güvenliği | Her istemci örneği kendi dosyasına yazar (`fq-<konak özeti>-<pid>-<rastgele>.jsonl`), kilit gerekmez. Sahibi aynı konakta ölmüş günlük hemen, başka konaktaki ya da yanıt vermeyen sahibin günlüğü 2 dakika yazılmadıysa devralınır; devralma atomik yeniden adlandırmadır, iki süreç aynı günlüğü alamaz. Canlı süreç 30 sn'de bir kalp atışı yazar ve sonradan sahipsiz kalan günlükleri devralır |
| Sınırlar | Gövde baytı `storageMaxBytes` üstüne çıkınca en eski olaylar atılır; `storageMaxAgeMs` süresinden eski olay gönderilmez. Atılanlar `getStatus().dropped` sayacına girer |
| İzin | `setConsent({ analytics: false })`, `optOut()` ve `reset()` diskteki kuyruğu da siler. Devralınan olay kendi `consent` alanıyla gider |
| Hata | Dizin oluşturulamaz ya da yazılamazsa kurucu fırlatır. Çalışma zamanındaki yazım hatası uygulamaya fırlatılmaz: uyarı yazılır, kuyruk bellekte sürer (`getStatus().storage` null olur) |
| Gizlilik | Dizin ve dosya yalnız süreç kullanıcısına açılır (POSIX `0700`/`0600`; Windows'ta dizin ACL'i devralınır). Olay gövdeleri diskte düz JSON durur; proje anahtarı yazılmaz |
| Dayanıklılık | Yazım `fsync` yapmaz: süreç çökmesinde olaylar işletim sistemi önbelleğinden diske iner, güç kesintisinde son satırlar kaybolabilir. Yarım kalan ve bozuk satır okunurken atlanır |

## Bilinçli eksikler

Yakalanmamış istisna ve Promise reddi otomatik dinlenmez (`process.on("uncaughtException")` içinde `captureError(err, { origin: "uncaught_exception", fatal: true })` çağırın, ardından `close()`). OTel yoktur; `trackRevenue` `feralin_purchase` istemci beyanı üretir, doğrulama sunucudadır.

## Geliştirme

```bash
pnpm --filter @feralin/node build
pnpm --filter @feralin/node test
DATABASE_URL='postgres://kullanici:parola@127.0.0.1:5432/test_db?sslmode=disable' pnpm --filter @feralin/node test:e2e
```

Son komut `services/collect`'i başlatır, paketi boş dizine kurar, gerçek olay gönderir ve testin kendi kimliklerini `collect_outbox` üzerinde doğrular. Yalnız test veritabanı kullanın.
