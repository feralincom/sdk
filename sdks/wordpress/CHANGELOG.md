# Değişiklik günlüğü

Eklenti wordpress.org'a yayınlanmadı (SVN erişimi yok) ve gerçek bir WordPress ya da WooCommerce kurulumunda hiç çalıştırılmadı (`BLOCKED_EXTERNAL`). Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## Yayınlanmamış

- Tamamlanan WooCommerce siparişi artık `order_completed` yerine PHP SDK `trackRevenue` ile `feralin_purchase` gönderir: `transaction_id` = `woo:order:<id>` (WooCommerce webhook ile aynı, defterde çift sayım yok, webhook iadeleri bu satın almaya bağlanır), tutar ISO 4217 küçük biriminde tam sayı; eski `value` (ondalık) alanı kalktı, `feralin_order_event_properties` süzgeci yalnız ek alanları değiştirir. İade kancası eklenmedi: SDK gelir sözleşmesinde iade olayı yok, iadeler webhook ile gelir. Saplı PHPUnit ile sınandı (16 Kasım 2026).

## 0.1.0 (yayınlanmadı)

- İlk eklenti: ayar sayfası (proje anahtarı doğrulaması, `sk_` reddi), genel sayfalara Web SDK ekleme, WooCommerce siparişi tamamlanınca PHP SDK ile sunucu olayı; siparişte izin kaydı, gönderilemeyen olay için zamanlanmış yeniden deneme, kaldırmada ayarların silinmesi, Türkçe dil dosyası (4 Kasım 2026).
- WordPress çekirdeği olmadan ince saplarla PHPUnit testleri ve paket tanımı (`composer.json`, `phpunit.xml.dist`); README gerçek doğrulama durumuna uyduruldu (12 Kasım 2026).
