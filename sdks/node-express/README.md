# @feralin/express

`@feralin/node` üstünde Express ara katmanı. Her isteğe `req.feralin` ekler; izin ve kimlik o isteğin kullanıcısından alınıp her olaya geçirilir.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (gerçek Express 5, gerçek HTTP) | Geçiyor |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs node-express` ile geçti |
| Express 4 | Peer aralığında, sınanmadı |
| npm yayını | npm'de yayımlandı: `@feralin/express@0.1.0` (17 Kasım 2026, `@feralin` organizasyonu); sürüm ve özet registry'den geri okundu |

## Kurulum

Çekirdek peer bağımlılığıdır, iki paket birlikte kurulur:

```bash
npm install @feralin/node @feralin/express
```

## Kullanım

```ts
import express from "express";
import { feralinMiddleware } from "@feralin/express";

const app = express();
const feralin = feralinMiddleware({
  projectKey: process.env.FERALIN_PROJECT_KEY!, // pk_… anahtarı; kaynak koda yazmayın
  collectUrl: "https://collect.example.com",
  resolveConsent: (req) => izniOku(req), // { analytics, advertising }
  resolveUserId: (req) => req.user?.id,
});
app.use(feralin);

app.post("/siparis", (req, res) => {
  req.feralin.track("order_completed", { order_id: "ord_1" });
  res.sendStatus(201);
});

process.once("SIGTERM", () => void feralin.close());
```

## İstek kapsamı

İstemci süreçte tektir, izin ve kimlik isteğe aittir. İstek başına yol: `resolveConsent` ve `resolveUserId` ile `req.feralin.track`. Kimlik işleyicide belli oluyorsa olay başına verin: `req.feralin.track(ad, ozellikler, { userId, consent })`. İstek dışı işlerde de `feralin.client.track(ad, ozellikler, { consent, userId })` kullanılır.

`feralin.client` yalnız süreç düzeyinde `flush` ve `getStatus` içindir. İstek işlerken `client.identify`, `client.setConsent`, `client.optOut` ve `client.reset` **çağırmayın**: bir kullanıcının kimliği ve izni herkesin olayına geçer, `analytics=false` bütün istekleri durdurur ve kuyruğu siler. `resolveConsent` verilmediğinde her istek bu istemcinin varsayılan iznini okur, bu nedenle son kullanıcısı olan uygulamada `resolveConsent` verin.

## İzin

İzin kararı uygulamanındır. `resolveConsent` yoksa istemci varsayılanı geçerlidir (varsayılan `analytics=false`). `undefined` dönerse veya hata atarsa izin yok sayılır, istek düşmez. `fr_click` yalnız `advertising === true` iken gider.

## Veri

IP, User-Agent ve çerez okunmaz. `page_url` sorgusuz, `referrer` yalnız origin, `locale` ilk dil etiketidir. Yolda kişisel veri varsa `includeContext: false` verin. `trackRequests: true` yanıt bitince `http_request` üretir ve yol yerine rota kalıbını yazar.

## Desteklenmeyenler

Anonim kimlik ve oturum üretilmez, uygulama `resolveAnonymousId` ve `resolveSessionId` ile verir. `group`, `setUserProperties`, `trackRevenue`, hata raporlama, OTel ve kalıcı kuyruk yoktur.
