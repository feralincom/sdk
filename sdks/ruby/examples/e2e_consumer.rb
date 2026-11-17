# frozen_string_literal: true

# Gerçek services/collect tüketicisi: scripts/sdk-e2e/run.mjs ruby tarafından temiz GEM_HOME ile çalıştırılır.
# Gem paketlenip kurulur; denetim satırları sdks/android/scripts/outbox_check.go ile PostgreSQL üzerinde doğrulanır.

require "json"
require "net/http"
require "uri"
require "feralin"

COLLECT_URL = ENV.fetch("FERALIN_E2E_COLLECT_URL")
PROJECT_KEY = ENV.fetch("FERALIN_E2E_PROJECT_KEY")
CHECKS = ENV.fetch("FERALIN_E2E_CHECKS")

def must(condition, message)
  abort("KALDI: #{message}") unless condition
end

def expect(line)
  File.open(CHECKS, "a", encoding: "utf-8") { |file| file.puts(line) }
end

def report(name, detail)
  puts "  OK #{name}: #{JSON.generate(detail)}"
end

def make(key = PROJECT_KEY, **options)
  Feralin::Client.new(key, COLLECT_URL, flush_interval: 0, **options)
end

# Kaynak ağaçtan değil, kurulu gem'den çalışıldığının ve bağımlılık gelmediğinin kanıtı.
spec = Gem.loaded_specs.fetch("feralin")
gem_home = File.expand_path(ENV.fetch("GEM_HOME"))
must(File.expand_path(spec.full_gem_path).start_with?(gem_home), "gem GEM_HOME dışından yüklendi: #{spec.full_gem_path}")
must(spec.runtime_dependencies.empty?, "çalışma zamanı bağımlılığı olmamalı")
must(!defined?(::Rails) && !defined?(::Rack::Builder), "Rails veya rack yüklenmemeliydi")
puts "  kurulu paket: #{spec.full_gem_path}"

# 202 + outbox satırı + fr_click reklam izniyle
client = make(consent: Feralin::Consent.new(analytics: true, advertising: true))
event = client.track("order_completed", { order_id: "ord_rb_1", fr_click: "clk_rb_1" }, user_id: "user_rb_1")
result = client.flush
must(event && result.status == 202 && result.accepted == 1, "202 bekleniyordu")
expect("frclick #{result.batch_id}")
expect("once #{event['event_id']}")
expect("platform ruby:#{event['event_id']}")
report("202-outbox-frclick", { status: result.status, batch_id: result.batch_id })

# Reklam izni yok: fr_click çıkarılır
client = make(consent: Feralin::Consent.new(analytics: true))
event = client.track("order_completed", { order_id: "ord_rb_2", fr_click: "clk_rb_2" })
must(event && !event["properties"].key?("fr_click"), "fr_click çıkarılmalıydı")
result = client.flush
must(result.status == 202, "202 bekleniyordu")
expect("nofrclick #{result.batch_id}")
report("frclick-izinsiz-cikarildi", { status: result.status })

# İzinsiz: SDK olay üretmez
client = make
must(client.track("order_completed").nil? && client.flush.sent.zero?, "izinsiz olay üretilmemeliydi")
report("izinsiz-sdk-uretmez", { sent: 0 })

# İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
event_id = format("01JCRB%020d", Process.clock_gettime(Process::CLOCK_REALTIME, :nanosecond))[0, 26]
body = JSON.generate(
  {
    events: [
      {
        event_id: event_id,
        event_name: "denied_event",
        occurred_at: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        platform: "ruby",
        schema_version: 1,
        consent: { analytics: false }
      }
    ]
  }
)
uri = URI.parse("#{COLLECT_URL}/v1/batch")
response = Net::HTTP.start(uri.host, uri.port, read_timeout: 10) do |http|
  http.post(uri.request_uri, body, {
              "Content-Type" => "application/json",
              "X-Feralin-Project-Key" => PROJECT_KEY,
              "Idempotency-Key" => Feralin::Events.idempotency_key_for([event_id])
            })
end
denied = JSON.parse(response.body)
must(response.code == "202" && denied["accepted"].zero? && denied["rejected_reasons"]["consent_denied"] == 1,
     "toplayıcı izinsiz olayı reddetmeliydi")
expect("absent #{event_id}")
report("izinsiz-toplayici-red", denied["rejected_reasons"])

# Yanlış anahtar: 401, olay atılır, uygulama düşmez
warnings = []
quiet = Object.new
quiet.define_singleton_method(:debug) { |_message = nil| nil }
quiet.define_singleton_method(:warn) { |message = nil| warnings << message.to_s }
client = make("pk_test_wrong_key_000", consent: Feralin::Consent.new(analytics: true), logger: quiet)
event = client.track("order_completed", { order_id: "ord_rb_wrong" })
result = client.flush
must(result.error.is_a?(Feralin::RejectedError) && result.status == 401 && result.rejected == 1 && client.size.zero?,
     "401 bekleniyordu")
must(warnings.none? { |line| line.include?("pk_test_wrong_key_000") }, "anahtar günlüğe yazılmamalıydı")
expect("absent #{event['event_id']}")
report("yanlis-anahtar-401", { status: result.status })

# Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
keys = []
lossy = lambda do |url, data, headers, timeout|
  keys << headers.fetch("Idempotency-Key")
  answer = Feralin::Transport.net_http(url, data, headers, timeout)
  raise Feralin::TemporaryError.new("yanıt yolda kayboldu", status: 0) if keys.length == 1

  answer
end
client = make(consent: Feralin::Consent.new(analytics: true), transport: lossy)
event = client.track("order_completed", { order_id: "ord_rb_retry" })
lost = client.flush
must(lost.error.is_a?(Feralin::TemporaryError) && client.size == 1, "yanıt kaybı kuyrukta tutulmalıydı")
following = client.track("order_shipped", { order_id: "ord_rb_retry" })
result = client.flush
must(result.ok? && result.status == 202 && client.size.zero?, "tekrar 202 vermeliydi")
must(keys.length == 3 && keys[0] == keys[1], "aynı anahtar bekleniyordu")
expect("once #{event['event_id']}")
expect("once #{following['event_id']}")
report("idempotency-tekrar", { key: keys[0] })

# Rack middleware: her isteğin kendi izni ve kimliği; gerçek toplayıcıya yanıttan sonra gider
client = make
Feralin.client = client
consent = ->(env) { Feralin::Consent.new(analytics: env["HTTP_X_ANALITIK"] == "1") }
produced = {}
app = lambda do |env|
  tracker = env.fetch(Feralin::Rack::ENV_KEY)
  tracker.identify("user_rb_rack") if env["HTTP_X_ANALITIK"] == "1"
  produced[env["HTTP_X_ANALITIK"]] = tracker.track("order_completed", { order_id: "ord_rb_rack", fr_click: "clk_rb_rack" })
  [200, { "content-type" => "text/plain" }, ["ok"]]
end
stack = Feralin::Rack::Middleware.new(app, consent: consent, flush_after_request: true)
stack.call({ "REQUEST_METHOD" => "POST", "PATH_INFO" => "/siparis", "HTTP_X_ANALITIK" => "1" })
stack.call({ "REQUEST_METHOD" => "POST", "PATH_INFO" => "/siparis", "HTTP_X_ANALITIK" => "0" })
accepted = produced["1"]
must(accepted && accepted["user_id"] == "user_rb_rack" && produced["0"].nil?, "istek başına izin uygulanmalıydı")
must(client.size.zero?, "flush_after_request kuyruğu boşaltmalıydı")
expect("once #{accepted['event_id']}")
expect("nofrclickevent #{accepted['event_id']}")
expect("platform ruby:#{accepted['event_id']}")
report("rack-istek-basina-izin", { event_id: accepted["event_id"] })

puts "ruby tüketici: tüm senaryolar geçti"
