<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# WordPress / WooCommerce: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/wordpress/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | PHP |
| Paket | `feralin` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/wordpress` |
| Registry | wordpress.org: **BLOCKED_EXTERNAL** (gereken: wordpress.org eklenti incelemesi ve SVN erişimi) |
| Derleme | `node sdks/wordpress/scripts/build.mjs` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `wordpress.org` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
pnpm --filter @feralin/web build
node sdks/wordpress/scripts/build.mjs
# WP_DIZINI: WordPress kurulumunun kökü
cp -r sdks/wordpress/dist/feralin WP_DIZINI/wp-content/plugins/feralin
```

## İlk kullanım

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

```js
feralin.setConsent({ analytics: true, advertising: false });
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (sayfa izleme Web SDK ile, gerçek WordPress'te e2e; registry yayını yok) |
| batch | PARTIAL (Web SDK kuyruğu ve PHP SDK gönderimi gerçek kurulumda çalıştı; WP-Cron yeniden denemesi yalnız saplı testte) |
| consent | SUPPORTED (izin yokken olay yok, ödeme anı izni feralin_checkout_consent süzgeciyle; gerçek kurulumda e2e. WP Consent API eklentisiyle koşmadı) |
| identity | PARTIAL (WordPress kullanıcı kimliği tuzlu takma ada çevrilir; saplı testte, gerçek kurulumda misafir siparişle koşuldu) |
| attribution | PARTIAL (fr_click feralin_order_event_properties süzgeciyle; saplı testte, gerçek kurulumda koşmadı) |
| deeplink | N/A |
| revenue | SUPPORTED (WooCommerce siparişi tamamlanınca bir kez feralin_purchase, transaction_id woo:order:<id>, tutar küçük birimde; gerçek WooCommerce 11.3.1 ile e2e. İstemci beyanıdır, verified gönderilmez) |
| error | PLANNED |
| replay | PLANNED (yalnız Web SDK üzerinden) |
| tracing | N/A |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS | php -l; eklenti gerçek WordPress ve WooCommerce'te etkinleşti ve çalıştı (scripts/sdk-e2e/run.mjs wordpress (24 Kasım 2026, WSL): resmî WordPress 7.1.5 (SHA-1 doğrulandı) ve WooCommerce 11.3.1, koşuya özgü MariaDB, PHP 8.3 yerleşik sunucusu, gerçek services/collect ve ClickHouse). |
| build | PASS | scripts/build.mjs eklenti dizinini üretir (Web SDK ve PHP SDK içinde); bu çıktı temiz WordPress'e kopyalanıp etkinleştirildi. feralin.com indirme paketi (feralin-wordpress-*.zip) aynı dizinden üretilir. |
| test | PASS | PHPUnit 20 test (saplı) ve gerçek kurulum e2e: ayarlarda sk_ reddi (Settings API temizleyicisi), sayfada betik ve başlangıç kodu, izin yokken olay yok, izinden sonra page_view ve özel olay, izinli WooCommerce siparişinde tek feralin_purchase, izinsiz siparişte olay yok (scripts/sdk-e2e/run.mjs wordpress (24 Kasım 2026, WSL): resmî WordPress 7.1.5 (SHA-1 doğrulandı) ve WooCommerce 11.3.1, koşuya özgü MariaDB, PHP 8.3 yerleşik sunucusu, gerçek services/collect ve ClickHouse). WP Consent API eklentisi, WP-Cron yeniden denemesi ve gerçek tarayıcı (jsdom yerine) koşmadı. |
| registry | BLOCKED_EXTERNAL | wordpress.org SVN erişimi yok. |
| clean_install | PASS | Boş WordPress kurulumuna eklenti dizini kopyalandı, activate_plugin ile etkinleşti, ayarlar kaydedildi; WooCommerce ile birlikte. |
| event_receipt | PASS | 3 ön yüz olayı (Web SDK, platform web) ve 1 sipariş olayı (PHP SDK, platform php) gerçek toplayıcıda 202, outbox'ta ve ClickHouse'ta tam bir kez; kaynak sütunları web:127.0.0.1 ve server:. |
| documentation | PASS | docs/sdk/wordpress.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
