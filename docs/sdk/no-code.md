# Kod yazmadan kurulum: Wix, Webflow, Bubble, Shopify

**Durum (6 Kasım 2026):** Bu platformlar için Feralin uygulaması veya eklentisi yoktur. Bu belge yalnız bugün var olan iki yolu anlatır: Web SDK betiği (`feralin.iife.js`) ve REST (`POST /v1/batch`). Matris satırları: `docs/sdk/capability-matrix.md` #24 ve #25.

**Resmî bir Shopify uygulaması yoktur.** Uygulama mağazasında Feralin bulunmaz, sipariş webhook'u işlenmez, sipariş tutarı `verified` olmaz. Shopify Partner hesabı ve uygulama incelemesi `BLOCKED_EXTERNAL`.

## Neyin sınandığı

| Konu | Sonuç |
|---|---|
| Aşağıdaki kod blokları | Bu dosyadan okunur, jsdom ve gerçek `services/collect` + PostgreSQL ile çalıştırılır: `node scripts/sdk-e2e/run.mjs no-code` |
| `window.Shopify` ve Customer Events nesneleri | Testte taklittir; adlar Shopify'ın geliştirici belgelerinden alındı |
| Gerçek Wix, Webflow, Bubble, Shopify sitesi | **Denenmedi.** Hesap ve test sitesi yok (`BLOCKED_EXTERNAL`) |
| Platform menü adları ve plan şartları | Platform belgelerinden aktarıldı, ekranda doğrulanmadı; değişmiş olabilir |

Adresler live-dev içindir. Betik `https://feralin.com/sdk/feralin.iife.js`, toplayıcı `https://feralin.com/collect`. Üretim ortamı ve CDN henüz yoktur. `pk_live_BURAYA` yerine panelden aldığınız public proje anahtarını yazın. SDK yalnız `pk_` ile başlayan anahtarı kabul eder, boşlukları kırpar; gizli anahtarı (`sk_`) asla sayfaya koymayın, SDK bunu ve başka önekleri kurulumda reddeder. Yanlış anahtarda `feralin.initialize` hata fırlatır ve `feralinOlay` olay üretmez.

**Betik bütünlüğü (SRI) bugün yoktur.** Betik sürümsüz bir adresten `integrity` özniteliği olmadan yüklenir, çünkü içeriği sabit kalan sürümlü dosya henüz yayınlanmıyor; özet yazılsa her güncellemede betik sessizce engellenirdi. Riski açıkça bilin: `feralin.com` veya dağıtım yolu ele geçirilirse değiştirilmiş betik sitenizde sayfanın tüm yetkisiyle çalışır, tarayıcı bunu fark etmez. Ödeme veya hesap sayfası gibi hassas sayfalara koymadan önce bu riski değerlendirin. Sürümlü dosya ve yayımlanan özet olmadıkça bu sınır kalkmaz; adresler de henüz yalnız live-dev içindir.

## Ortak betik (Wix, Webflow, Bubble)

İzin gelmeden olay üretilmez ve depoya kimlik yazılmaz. Bu betik izni kendisi sormaz: kendi çerez bandınız veya izin aracınız izin verince `feralinIzin(...)` çağrılmalıdır. Olayı `feralin.track` yerine `feralinOlay` ile gönderin: betik yüklenmeden yapılan çağrı hata vermez, `null` döner. Reklam izni yoksa `fr_click` değerini Web SDK çekirdeği çıkarır; yardımcıdaki aynı süzgeç zararsız bir tekrardır.

<!-- snippet:genel -->
```html
<script src="https://feralin.com/sdk/feralin.iife.js" defer></script>
<script>
  (function () {
    var hazir = false;
    var bekleyenIzin = null;
    window.feralinIzin = function (izin) {
      if (hazir) feralin.setConsent(izin);
      else bekleyenIzin = izin;
    };
    window.feralinOlay = function (ad, ozellikler) {
      if (!hazir) return null;
      var kopya = Object.assign({}, ozellikler);
      if (feralin.getStatus().consent.advertising !== true) delete kopya.fr_click;
      return feralin.track(ad, kopya);
    };
    window.addEventListener("load", function () {
      feralin.initialize({ projectKey: "pk_live_BURAYA", collectUrl: "https://feralin.com/collect" });
      hazir = true;
      if (bekleyenIzin) feralin.setConsent(bekleyenIzin);
    });
  })();
</script>
```

İzin aracınızdan çağrı örneği:

```js
feralinIzin({ analytics: true, advertising: false });
feralinOlay("signup_completed", { plan: "growth" });
```

`page_view` izin verildiğinde bir kez, sayfa yüklemesi başına üretilir. Tam sayfa yenilemesi olmayan geçişlerde yeni `page_view` üretilmez; o geçişlerde `feralinOlay("page_view")` çağrısı gerekir. Hangi geçişin bu türden olduğu platforma bağlıdır ve sınanmadı.

### Wix

Site panelinde Ayarlar, Development & integrations, Custom Code, ardından **Add Custom Code**. Kodu **Head** konumuna ekleyin ve tüm sayfalara uygulayın. Wix belgesine göre site yayınlanmış olmalı ve bağlı alan adı bulunmalıdır; alan adı değişirse kod parçaları silinir.

### Webflow

Betik site geneli özel kod alanına, yani head bölümüne eklenir (Site settings, Custom code). Değişiklik yayınlanana kadar etkisizdir. Webflow'un yardım sayfası bu belge yazılırken açılamadı: menü yolunu ve plan şartını kendi hesabınızda doğrulayın.

### Bubble

Ayarlar, SEO / metatags, Advanced settings altındaki **Script/meta tags in header** alanına ekleyin. Bu alana yalnız `<script>`, `<meta>` ve `<link>` etiketleri yazılır. Olay göndermek için sayfada JavaScript çalıştıran bir eylem gerekir (genellikle Toolbox eklentisinin **Run javascript** eylemi); bu yol sınanmadı. Bubble sayfaları arasında tam yenileme olmayan geçişler için yukarıdaki `page_view` notu geçerlidir.

## REST (Bubble API Connector ve benzerleri)

Betik çalıştıramayan iş akışları olayı sunucudan gönderebilir. İzni siz taşırsınız: son kullanıcının izni yoksa isteği hiç yapmayın.

```http
POST https://feralin.com/collect/v1/batch
Content-Type: application/json
X-Feralin-Project-Key: pk_live_BURAYA
Idempotency-Key: <aynı içerik için aynı kalan, 8-128 karakter değer>

{"events":[{
  "event_id": "<16-64 karakter, harf rakam ve tire; olay başına benzersiz>",
  "event_name": "order_completed",
  "occurred_at": "2026-11-06T10:00:00Z",
  "platform": "other",
  "schema_version": 1,
  "consent": { "analytics": true },
  "properties": { "order_id": "ord_1" }
}]}
```

- Yanıt `202` ise kabul edilmiştir. `accepted` 0 ve `rejected_reasons.consent_denied` 1 ise olay izin nedeniyle yazılmamıştır.
- `401`, anahtar yanlış demektir; tekrar denemeyin. `429`, `5xx` veya ağ hatasında **aynı gövde ve aynı `Idempotency-Key`** ile yeniden deneyin. Bubble'ın yeniden deneme ve sıra davranışı sınanmadı.
- `tenant_id`, `project_id` ve `verified` göndermeyin. E-posta, telefon veya ad göndermeyin. `fr_click` yalnız `consent.advertising` `true` iken gönderilir.
- Bubble API Connector'da başlıklar ortak başlık olarak tanımlanır, çağrı **action** olarak kullanılır. Bubble belgesine göre **Initialize** gerçek istek atar; test projesinin anahtarıyla yapın.

## Shopify

Resmî uygulama olmadığından iki parça elle eklenir. Tema değişikliği tema güncellemesinde kaybolabilir.

### Tema betiği

`layout/theme.liquid` dosyasında `</head>` öncesine eklenir. İzin Shopify'ın Customer Privacy API'sinden okunur. API yüklenemezse izin bilinmiyor sayılır, olay üretilmez.

<!-- snippet:shopify-tema -->
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

### Sipariş olayı (Customer Events, custom pixel)

Tema betiğine güvenerek ödeme sayfası ölçülemez; sipariş olayı için Shopify yöneticisinde Ayarlar, Customer events altında custom pixel eklenir. Pixel korumalı alanda çalışır, üst sayfaya erişemez, bu yüzden Web SDK kullanılmaz ve REST çağrılır. Olay kimliği sipariş kimliğinden türer; pixel aynı sipariş için yeniden tetiklenirse aynı `Idempotency-Key` ikinci satır yazdırmaz.

<!-- snippet:shopify-pixel -->
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

Bu tutar tarayıcıdan gelir ve **doğrulanmış gelir değildir**. İade ve iptal görünmez. Ağ hatasında yeniden deneme yoktur: pixel yeniden tetiklenmedikçe olay kaybolur.

## Desteklenmeyenler

- Resmî Shopify, Wix veya Webflow uygulaması, tek tıkla kurulum, mağaza listesi.
- Shopify sipariş webhook'u, `verified` gelir, iade ve abonelik olayları (F5).
- Shopify ödeme sayfasında tema betiği ve pixel dışında ölçüm.
- Sürümlü betik dosyası ve SRI özeti (yukarıya bakın).
- Session replay, heatmap, hata raporlama.
