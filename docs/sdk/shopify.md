<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Shopify: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `docs/sdk/no-code.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | JavaScript, REST |
| Paket | yok (kaynak dizin) |
| Sürüm | yok |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `docs/sdk/no-code.md` |
| Registry | Shopify App Store: **BLOCKED_EXTERNAL** (gereken: Shopify Partner hesabı, uygulama geliştirme ve inceleme) |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `Shopify App Store` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```html
<script src="https://feralin.com/sdk/feralin.iife.js" defer></script>
<script>
  (function () {
    var hazir = false;
    function izniUygula() {
      var gizlilik = window.Shopify.customerPrivacy;
      feralin.setConsent({ analytics: gizlilik.analyticsProcessingAllowed(), advertising: gizlilik.marketingAllowed() });
    }
    window.feralinOlay = function (ad, ozellikler) {
      if (!hazir) return null;
      var kopya = Object.assign({}, ozellikler);
      if (feralin.getStatus().consent.advertising !== true) delete kopya.fr_click;
      return feralin.track(ad, kopya);
    };
    window.addEventListener("load", function () {
      feralin.initialize({ projectKey: "pk_live_BURAYA", collectUrl: "https://feralin.com/collect" });
      hazir = true;
      window.Shopify.loadFeatures([{ name: "consent-tracking-api", version: "0.2" }], function (hata) {
        if (hata) return;
        izniUygula();
        document.addEventListener("visitorConsentCollected", izniUygula);
      });
    });
  })();
</script>
```

## İlk kullanım

```js
var izin = init.customerPrivacy;
api.customerPrivacy.subscribe("visitorConsentCollected", function (olay) {
  izin = olay.customerPrivacy;
});

analytics.subscribe("checkout_completed", function (olay) {
  if (!izin.analyticsProcessingAllowed) return;
  var odeme = olay.data.checkout;
  if (!odeme.order || !odeme.order.id) return;
  var kimlik = ("shopify-" + odeme.order.id).replace(/[^0-9A-Za-z-]/g, "-").slice(0, 64);
  fetch("https://feralin.com/collect/v1/batch", {
    method: "POST",
    keepalive: true,
    headers: { "Content-Type": "application/json", "X-Feralin-Project-Key": "pk_live_BURAYA", "Idempotency-Key": kimlik },
    body: JSON.stringify({
      events: [
        {
          event_id: kimlik,
          event_name: "order_completed",
          occurred_at: new Date().toISOString(),
          platform: "other",
          schema_version: 1,
          consent: { analytics: true, advertising: izin.marketingAllowed === true },
          properties: {
            order_id: String(odeme.order.id),
            value: odeme.totalPrice ? odeme.totalPrice.amount : undefined,
            currency: odeme.totalPrice ? odeme.totalPrice.currencyCode : undefined,
          },
        },
      ],
    }),
  });
});
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | PARTIAL (tema snippet'i; gerçek mağazada sınanmadı) |
| batch | PARTIAL (tema: #1 kuyruğu; pixel: tek istek, yeniden deneme yok) |
| consent | PARTIAL (Customer Privacy API okunur; taklitle sınandı) |
| identity | PARTIAL (#1 identify ve reset) |
| attribution | PARTIAL (#1 ile aynı; fr_click reklam iznine bağlı) |
| deeplink | N/A |
| revenue | PLANNED (order webhook ve verified yok; pixel tutarı doğrulanmamış) |
| error | N/A |
| replay | N/A |
| tracing | N/A |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PARTIAL | Resmî uygulama kodu yok; yalnız belgedeki tema ve pixel blokları. |
| build | NOT_APPLICABLE |  |
| test | PASS | Bloklar taklit window.Shopify, init, api ve analytics ile çalıştırıldı. |
| registry | BLOCKED_EXTERNAL | Resmî Shopify uygulaması yok. |
| clean_install | BLOCKED_EXTERNAL | Shopify mağazası ve geliştirici hesabı yok; gerçek temaya kurulmadı. |
| event_receipt | PARTIAL | scripts/sdk-e2e/run.mjs no-code: taklit Shopify nesneleri, gerçek toplayıcı. Gerçek mağaza KOŞMADI. |
| documentation | PASS | docs/sdk/shopify.md: kurulum ve kullanım kod blokları docs/sdk/no-code.md içindeki snippet:shopify-* işaretli bloklardan, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
