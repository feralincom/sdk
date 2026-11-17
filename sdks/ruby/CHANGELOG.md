# Değişiklikler

## Yayınlanmamış

- `track_revenue` → `feralin_purchase`, `group` → `fr_group`, `set_user_properties` → `fr_user_properties`, `capture_error` → `fr_error` (Android SDK ile aynı gövde, ham backtrace yok, 60 sn'de 20 olay, parmak izi başına 3); `app_version:` ve `error_sample_rate:` seçenekleri; Rack `Tracker` aynı yöntemleri isteğin kimliği ve izniyle sunar. Minitest ile sınandı (16 Kasım 2026).

## 0.1.0

- İlk sürüm: `Feralin::Client`, Rack middleware, Rails Railtie. Henüz RubyGems'e yayınlanmadı.
