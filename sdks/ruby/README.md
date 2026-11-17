# Feralin Ruby SDK (`feralin`)

Feralin toplayıcısına (`POST /v1/batch`) sunucu tarafından olay gönderen Ruby SDK'sı. Rack middleware ve Rails Railtie içerir. Yalnız standart kütüphane kullanır (`net/http`, `json`, `securerandom`); çalışma zamanı bağımlılığı yoktur. Rails ve rack gem'in bağımlılığı değildir.

## Durum

Henüz RubyGems'e yayınlanmadı (`BLOCKED_EXTERNAL`: RubyGems hesabı, 2FA ve `feralin` adının doğrulanması gerekir). `gem install feralin` bugün bu paketi kurmaz.

Yalnız Ruby 3.3.12 (Windows, `x64-mingw-ucrt`), Rails 8.1.4.1 ve rack 3.2.8 ile koşuldu; `required_ruby_version` 3.0'a izin verse de daha eski Ruby, Rails ve rack sürümleri denenmedi. Puma ve Unicorn altında çalıştırılmadı. Gerçek `Process.fork` testi Windows'ta atlanır; çatallanma orada pid değişimi taklit edilerek sınanır, gerçek çatallanma Linux'ta henüz koşulmadı.

## Kurulum

Yayın öncesi, depodan paketleyip kurun:

```bash
cd sdks/ruby
gem build feralin.gemspec
gem install --local feralin-0.1.0.gem
```

## En kısa örnek

```ruby
require "feralin"

client = Feralin::Client.new(
  ENV.fetch("FERALIN_PROJECT_KEY"),   # yalnız pk_ kabul edilir, sk_ reddedilir
  "https://collect.example.com",
  consent: Feralin::Consent.new(analytics: true)
)

event = client.track("order_completed", { order_id: "ord_1", amount: 249.9 }, user_id: "user_42")
result = client.flush                 # fırlatmaz; sonuç result.error içinde
client.close                          # kalanı en çok 5 sn içinde gönderir
```

`flush` sonucu:

| Durum | `result` | Kuyruk |
|---|---|---|
| 202 | `ok?` doğru, `accepted`, `rejected`, `batch_id` | Boşalır |
| 4xx (429 hariç), 401 ve 403 dahil | `error` `Feralin::RejectedError` | Olaylar atılır, uygulama düşmez |
| 5xx, 429, ağ hatası | `error` `Feralin::TemporaryError` | Tutulur, aynı `Idempotency-Key` ile yeniden denenir |

Geri çekilme 1 sn ile 30 sn arasında üsteldir, yarım jitter eklenir ve `Retry-After` en az bekleme olarak uyulur. Açık `flush` çağrısı geri çekilmeyi beklemez.

`track` doğrulama hatasında `Feralin::InvalidEventError` fırlatır. Özellik değerleri JSON karşılığı olan türler olmalıdır; `Time`, `BigDecimal` ve benzeri nesneleri önce metne veya sayıya çevirin. `user_id` metin olmalıdır (`user.id.to_s`) ve e-posta gibi kişisel veri taşımamalıdır.

## İzin

`analytics` doğru değilse olay üretilmez ve `track` `nil` döner; varsayılan `Consent.new` izin vermez. Yalnız gerçek `true` izin sayılır.

- `advertising` doğru değilse `fr_click` olaydan çıkarılır.
- `client.set_consent(Feralin::Consent.new)` bekleyen olayları siler ve olay başına verilen izni de geçersiz kılar.
- `client.track("olay", nil, consent: izin)` yalnız o olayın iznidir. Çok kullanıcılı sunucuda izin ve kimliği istek başına tutun; `client.identify` süreçteki bütün isteklere uygulanır.

## Rack

```ruby
# config.ru
require "feralin"

Feralin.client = Feralin::Client.new(ENV.fetch("FERALIN_PROJECT_KEY"), ENV.fetch("FERALIN_COLLECT_URL"))

use Feralin::Rack::Middleware,
    consent: ->(env) { Feralin::Consent.new(analytics: env["HTTP_COOKIE"].to_s.include?("analitik=1")) }

run ->(env) {
  tracker = env["feralin.tracker"]
  tracker.identify("user_42")                       # yalnız bu istek için
  tracker.track("order_completed", { order_id: "ord_1" })
  [200, { "content-type" => "text/plain" }, ["ok"]]
}
```

- Middleware kendiliğinden olay üretmez; istek yolu ve sorgusu kişisel veri taşıyabilir.
- İzin çözücüsü hata verir veya `Feralin::Consent` dönmezse izin yok sayılır.
- `flush_after_request: true`: arka plan göndericisi kapalıyken (`flush_interval: 0`) olayları `rack.response_finished` veya `rack.after_reply` ile yanıttan sonra gönderir. Sunucu bunları sunmuyorsa gönderim yanıttan önce yapılır ve isteği uzatır.

## Rails

Gem `Gemfile` içinde olunca Railtie kendiliğinden yüklenir, middleware'i ekler ve kapanışta kuyruğu gönderir.

```ruby
# config/initializers/feralin.rb
Rails.application.config.feralin.consent_resolver = lambda do |env|
  Feralin::Consent.new(analytics: ActionDispatch::Request.new(env).cookies["analitik"] == "1")
end
```

```ruby
class OrdersController < ApplicationController
  def create
    feralin.identify(current_user.public_id)
    feralin.track("order_completed", { order_id: order.public_id })
  end
end
```

Anahtar ve adres `FERALIN_PROJECT_KEY` ve `FERALIN_COLLECT_URL` ortam değişkenlerinden veya `config.feralin.project_key` ve `config.feralin.collect_url` ayarlarından okunur. İkisi yoksa uygulama açılır, olay üretilmez ve durum günlüğe yazılır. Diğer ayarlar: `consent` (istemcinin varsayılan izni), `consent_resolver`, `flush_after_request`, `flush_interval`, `batch_size`, `queue_limit`, `timeout`.

## Çatallanma (Puma, Unicorn)

Kuyruk süreç başınadır. İstemci çatallanmadan önce oluşturulduysa yavru süreç ilk çağrıda boş kuyrukla ve kendi göndericisiyle başlar; üst süreçte bekleyen olaylar yavrudan gönderilmez.

## Gelir, kimlik ve hata

```ruby
client.track_revenue("ord_1", 4999, "TRY", product_id: "pro_monthly", user_id: "user_42")
client.group("acme-team", { plan: "team" }, user_id: "user_42")
client.set_user_properties({ plan: "pro" }, user_id: "user_42")
begin
  odeme_al
rescue StandardError => e
  client.capture_error(e, user_id: "user_42")
end
```

- `track_revenue` → `feralin_purchase`: tutar küçük birimde `Integer`, ISO 4217; kurallar diğer SDK'larla aynıdır, sözleşme dışı girdide `InvalidEventError`. `verified` hiçbir zaman gönderilmez. SDK sözleşmesinde iade olayı yoktur.
- `group` → `fr_group`, `set_user_properties` → `fr_user_properties`: kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer istemcide düşer; geçersizse `nil`.
- `capture_error` → `fr_error` (Android SDK ile aynı gövde): hata sınıfı adı, temizlenmiş en çok 200 karakterlik mesaj, gem ve standart kütüphane dışı ilk beş çerçevenin parmak izi, üst çerçeve (`işlev@dosya.rb`) ve en çok 5 konum (dosya taban adı, satır, işlev). Ham backtrace gitmez; 60 saniyede en çok 20 olay, aynı parmak izi için en çok 3. Kurucu: `app_version:`, `error_sample_rate:`. Fırlatmaz.
- Rack'te `env["feralin.tracker"]` aynı dört yöntemi isteğin kimliği ve izniyle sunar.

## Desteklenmeyenler

- Kalıcı kuyruk: olaylar bellektedir, süreç ölürse kaybolur. Sınır aşılırsa en eski olay atılır.
- `reset`, global özellikler, otomatik (Rack) hata yakalama, OTel izleme.
- Sidekiq veya ActiveJob bütünleşmesi. İş sürecinde `Feralin::Client` doğrudan kullanılabilir.
- Otomatik sayfa veya istek olayı, parmak izi, `fr_click` okuma. `verified`, `tenant_id` ve `project_id` istemciden gönderilmez.

## Geliştirme

```bash
cd sdks/ruby
ruby -S rake test
```

Gerçek rack ve Rails ile tümleşik test (genel gem dizinine dokunmaz):

```bash
cd sdks/ruby
GEM_HOME="$PWD/vendor/gems" GEM_PATH="$PWD/vendor/gems" ruby -S gem install railties rack tzinfo-data --no-document
GEM_HOME="$PWD/vendor/gems" GEM_PATH="$PWD/vendor/gems" ruby -S rake test:rails
```

`tzinfo-data` yalnız Windows'ta gerekir; Rails orada sistem saat dilimi verisi bulamaz.

Gerçek toplayıcıyla uçtan uca test (yalnız test veritabanı verin):

```bash
DATABASE_URL='postgres://...' COLLECT_ADDR=127.0.0.1:4712 node scripts/sdk-e2e/run.mjs ruby
```
