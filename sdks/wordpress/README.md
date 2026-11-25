# Feralin WordPress eklentisi

Genel sayfalara Web SDK ekler ve tamamlanan WooCommerce siparişlerini PHP SDK ile sunucu olayı olarak gönderir.

## Durum: `INTEGRATION_TESTED`

Eklenti gerçek WordPress ve WooCommerce kurulumunda uçtan uca sınandı (24 Kasım 2026, WSL; resmî WordPress 7.1.5, SHA-1 özeti doğrulandı, ve WooCommerce 11.3.1). Test boş bir siteye eklentiyi kurup etkinleştirir, ayarları Settings API temizleyicisinden geçirir (`sk_` anahtarı reddedilir), sayfayı açıp izin yokken olay gitmediğini ve izinden sonra Web SDK olaylarının gerçek toplayıcıya ulaştığını, izinli WooCommerce siparişinin bir kez `feralin_purchase` gönderdiğini ve izinsiz siparişin göndermediğini denetler; olaylar toplayıcının kuyruk tablosunda ve ClickHouse'ta tam bir kez bulunur. Ayrıca WordPress çekirdeği olmadan ince saplarla 20 PHPUnit testi koşar.

```bash
bash scripts/sdk-e2e/php-suite.sh   # PHP 8.1+ ve Composer gerekir (Windows'ta WSL içinde)
# Gerçek WordPress + WooCommerce e2e (Linux/WSL; PHP mysqli, MariaDB, PostgreSQL test veritabanı):
FERALIN_WP_ARCHIVE=~/wordpress.tar.gz FERALIN_WC_ARCHIVE=~/woocommerce.zip DATABASE_URL='postgres://...' node scripts/sdk-e2e/run.mjs wordpress
```

| Konu | Durum |
|---|---|
| Gerçek WordPress + WooCommerce | Geçti: kurulum, ayarlar, sayfa izleme, izin kapısı, sipariş olayı, toplayıcı ve ClickHouse alındısı |
| Sınanmayanlar | WP Consent API eklentisiyle birlikte çalışma, WP-Cron yeniden denemesi (yalnız saplı testte), gerçek tarayıcı (sayfa jsdom'da açıldı) |
| wordpress.org yayını | `BLOCKED_EXTERNAL`: SVN erişimi ve inceleme gerekir; eklenti bugün feralin.com'dan indirilen zip ile kurulur |

## Kurulum

wordpress.org yayını olmadığından eklenti depodan paketlenir ve sitenin eklenti dizinine kopyalanır:

```bash
pnpm --filter @feralin/web build
node sdks/wordpress/scripts/build.mjs
# WP_DIZINI: WordPress kurulumunun kökü
cp -r sdks/wordpress/dist/feralin WP_DIZINI/wp-content/plugins/feralin
```

Ardından **Eklentiler** sayfasından Feralin etkinleştirilir; anahtar ve toplayıcı adresi **Ayarlar > Feralin** sayfasından girilir.

## Kullanım

WP Consent API yoksa ödeme anındaki izin ve sipariş olayının tıklama kimliği temanın ya da bir eklentinin `functions.php` dosyasında süzgeçle verilir (süzgeçler `tests/PluginTest.php` içinde sınanır):

```php
// Ödeme anındaki izin: izin aracınızın kararını döndürün. null dönerse sipariş olayı gönderilmez.
add_filter('feralin_checkout_consent', static fn ($consent, $order) => [
    'analytics' => benim_izin_aracim('statistics'),
    'advertising' => benim_izin_aracim('marketing'),
], 10, 2);

// Tıklama kimliği (sizin sakladığınız fr_click değeri); reklam izni yoksa SDK çıkarır. Kişisel veri eklemeyin.
add_filter('feralin_order_event_properties', static fn (array $properties, $order) => $properties + [
    'fr_click' => benim_tiklama_kimligim($order),
], 10, 2);
```

Başka bir izin aracı kullanan sayfalarda tarayıcı tarafı:

```js
feralin.setConsent({ analytics: true, advertising: false });
```

## Davranış

- Ayarlar: **Ayarlar > Feralin**. Yalnız `pk_` anahtarı kabul edilir, `sk_` reddedilir. İzleme varsayılan olarak kapalıdır.
- **Sayfa izleme:** Karar yoksa Web SDK olay üretmez. WP Consent API varsa `statistics` analitik, `marketing` reklam izni olarak okunur. Başka bir izin aracında `feralin.setConsent({ analytics: true, advertising: false })` çağırın.
- **Sipariş olayı:** İzin ödeme anında siparişe yazılır (`feralin_checkout_consent` süzgeci). Sipariş tamamlanınca bir kez `feralin_purchase` gelir beyanı gider (PHP SDK `trackRevenue`; `transaction_id` = `woo:order:<id>`, tutar para biriminin küçük biriminde tam sayı, `quantity` = ürün adedi), izin yoksa gitmez. İşlem kimliği WooCommerce webhook bağlantısıyla aynıdır: ikisi birden açıksa sipariş defterde bir kez sayılır. İade için SDK olayı yoktur; iadeler WooCommerce webhook bağlantısıyla deftere girer. `feralin_order_event_properties` süzgeci yalnız ek alanları (`order_id`, `item_count`, `source`) değiştirir; tıklama kimliği `fr_click` olarak buradan eklenir, reklam izni yoksa SDK çıkarır.
- **Gizlilik:** Ad, e-posta, adres gönderilmez. WordPress kullanıcı kimliği site tuzuyla türetilmiş takma ada çevrilir.
- **Yeniden deneme:** Geçici hatada olay `feralin_pending_events` seçeneğine (autoload kapalı) yazılır, WP-Cron 1 dk ile 1 saat arası artan aralıkla aynı `event_id` ile dener.
- **Hata:** Hiçbir istisna sipariş veya sayfa akışına geçmez.

## Bilinen sınır

Bekleyen olaylar ödeme anındaki `consent` değerini taşır. Ziyaretçi izni sonradan geri çektiğinde, daha önce kuyruğa girmiş sipariş olayı geri alınmaz.
