<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# WordPress / WooCommerce: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/wordpress/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | PHP |
| Paket | `feralin` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | IMPLEMENTING |
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
| event | PLANNED (kod yazıldı; yalnız stub'lı birim testi, gerçek WP'de ÇALIŞTIRILMADI; BLOCKED_EXTERNAL) |
| batch | PLANNED (kod yazıldı; yeniden deneme ve cron stub'lı testte, gerçek WP'de ÇALIŞTIRILMADI; BLOCKED_EXTERNAL) |
| consent | PLANNED (WP Consent API kodu stub'lı testte, gerçek WP'de ÇALIŞTIRILMADI; BLOCKED_EXTERNAL) |
| identity | PLANNED (takma ad stub'lı testte, gerçek WP'de ÇALIŞTIRILMADI) |
| attribution | PLANNED (fr_click süzgeci stub'lı testte, gerçek WP'de ÇALIŞTIRILMADI) |
| deeplink | N/A |
| revenue | PLANNED (Woo siparişi feralin_purchase, transaction_id woo:order:<id>; saplı testte, gerçek WooCommerce'te ÇALIŞTIRILMADI) |
| error | PLANNED |
| replay | PLANNED (yalnız Web SDK üzerinden) |
| tracing | N/A |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PARTIAL | Kod yazıldı; php -l ve WordPress çekirdeksiz (ince saplı) PHPUnit 20/20 geçti; gerçek WordPress'te çalışmadı. |
| build | PARTIAL | Eklenti dizini üretilir; zip ve WP kurulumu denenmedi. |
| test | PARTIAL | PHPUnit 20 test (PHP 8.3.6, WSL; WordPress/WooCommerce sapları, sipariş olayı gerçek PHP SDK'sı ve yerel sahte toplayıcıyla). Gerçek WordPress ve WooCommerce yok. |
| registry | BLOCKED_EXTERNAL | wordpress.org SVN erişimi yok. |
| clean_install | BLOCKED_EXTERNAL | Gerçek WordPress test sitesi yok (çekirdek indirilmedi). |
| event_receipt | BLOCKED_EXTERNAL | Sipariş olayı yalnız yerel sahte toplayıcıya gitti; gerçek WooCommerce ve toplayıcı yok. |
| documentation | PASS | docs/sdk/wordpress.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
