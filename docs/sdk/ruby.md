<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Ruby / Rails: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/ruby/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Ruby |
| Paket | `feralin` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/ruby` |
| Registry | RubyGems: **BLOCKED_EXTERNAL** (gereken: RubyGems.org hesabı, MFA (UI and API); push_rubygem kapsamlı rubygems_ önekli API anahtarı (GEM_HOST_API_KEY) ya da pending trusted publisher; ad rezervasyonu yok, feralin ilk yayında alınır) |
| Derleme | `cd sdks/ruby && ruby -S gem build feralin.gemspec` |
| Test | `cd sdks/ruby && ruby -S rake test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `RubyGems` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
cd sdks/ruby
gem build feralin.gemspec
gem install --local feralin-0.1.0.gem
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız) |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil) |
| consent | SUPPORTED (yayınsız; istemci, olay ve Rack isteği düzeyinde) |
| identity | PARTIAL (identify, Rack istek başına; group, set_user_properties Minitest testli; reset ve global özellik yok) |
| attribution | N/A |
| deeplink | N/A |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; Minitest testli, gerçek toplayıcı e2e yok) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; Minitest testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS | gem build uyarısız; 0 çalışma zamanı bağımlılığı. |
| test | PASS | Minitest 55 test, 1 atlandı: gerçek Process.fork Windows'ta yok, çatallanma pid taklidiyle sınandı. rake test:rails ayrıca gerçek Rails 8.1.4.1 ve rack 3.2.8 ile 5 test geçti. |
| registry | BLOCKED_EXTERNAL | RubyGems.org hesabı yok. |
| clean_install | PASS | gem build çıktısı boş GEM_HOME içine --local ile kuruldu, yalnız feralin kuruldu; RubyGems.org'dan kurulum denenemez. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs ruby: 202, outbox, izinsiz red, 401, idempotency, Rack istek başına izin. |
| documentation | PASS | docs/sdk/ruby.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
