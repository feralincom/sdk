# frozen_string_literal: true

# Gerçek rack ve railties ile tümleşik test. Ayrı süreçte koşar: `rake test:rails`.
# Rails, gem'in bağımlılığı olmadığından testten önce GEM_HOME içine kurulmalıdır (README, Geliştirme).
# Rails bulunamazsa test atlanmaz, başarısız olur; koşmayan test geçmiş sayılmasın.

require "json"
require "socket"
require "rails"
require "action_controller/railtie"
require "rack/lint"
require "rack/mock"
require "minitest"

require "feralin"

# Gerçek soket üzerinde sahte toplayıcı: Railtie'nin kurduğu istemci net/http ile buraya gönderir.
COLLECTOR = TCPServer.new("127.0.0.1", 0)
RECEIVED = Queue.new
Thread.new do
  loop do
    socket = COLLECTOR.accept
    socket.gets
    length = 0
    while (line = socket.gets) && line != "\r\n"
      length = line.split(": ", 2)[1].to_i if line.downcase.start_with?("content-length:")
    end
    RECEIVED << JSON.parse(socket.read(length).force_encoding(Encoding::UTF_8))
    payload = JSON.generate({ batch_id: "01TESTBATCH0000000000000000", accepted: 1, rejected: 0 })
    socket.write("HTTP/1.1 202 Accepted\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
    socket.close
  end
rescue IOError
  nil
end

class SiparisController < ActionController::API
  def create
    event = feralin.track("order_completed", { order_id: "ord_rails", fr_click: "clk" }, user_id: "user_rails")
    render json: { event_id: event && event["event_id"] }
  end
end

class FeralinRailsApp < Rails::Application
  config.root = __dir__
  config.eager_load = false
  config.consider_all_requests_local = true
  config.secret_key_base = "feralin-rails-tumlesik-test"
  config.hosts.clear
  config.logger = Logger.new(File::NULL)
  config.feralin.project_key = "pk_test_rails_integration_01"
  config.feralin.collect_url = "http://127.0.0.1:#{COLLECTOR.addr[1]}"
  config.feralin.flush_interval = 0
  config.feralin.flush_after_request = true
end

FeralinRailsApp.initialize!
FeralinRailsApp.routes.draw { post "/siparis", to: "siparis#create" }

class RailsIntegrationTest < Minitest::Test
  def request(headers = {})
    Rack::MockRequest.new(FeralinRailsApp).post("/siparis", headers)
  end

  def test_railtie_is_loaded_when_rails_is_present
    assert defined?(Feralin::Railtie)
    assert_includes Rails.application.railties.map(&:class), Feralin::Railtie
    assert_instance_of Feralin::Client, Feralin.client
    assert_includes FeralinRailsApp.middleware.map(&:klass), Feralin::Rack::Middleware
    refute_includes Feralin.client.inspect, "pk_"
    refute_includes SiparisController.action_methods, "feralin", "yardımcı metot rota eylemi olmamalı"
  end

  def test_missing_key_leaves_application_running_without_client
    active = Feralin.client
    saved = ENV.to_h.slice("FERALIN_PROJECT_KEY", "FERALIN_COLLECT_URL")
    saved.each_key { |name| ENV.delete(name) }
    Feralin.client = nil
    Feralin::Railtie.start_client(ActiveSupport::OrderedOptions.new)
    assert_nil Feralin.client
    response = request({ "HTTP_X_ANALITIK" => "1" })
    assert_equal 200, response.status, response.body
    assert_nil JSON.parse(response.body).fetch("event_id")
  ensure
    Feralin.client = active
    saved&.each { |name, value| ENV[name] = value }
  end

  def test_controller_with_consent_reaches_collector
    response = request({ "HTTP_X_ANALITIK" => "1" })
    assert_equal 200, response.status, response.body
    event_id = JSON.parse(response.body).fetch("event_id")
    refute_nil event_id
    body = Timeout.timeout(5) { RECEIVED.pop }
    wire = body["events"].fetch(0)
    assert_equal event_id, wire["event_id"]
    assert_equal "ruby", wire["platform"]
    assert_equal "user_rails", wire["user_id"]
    refute wire.fetch("properties").key?("fr_click"), "reklam izni yokken fr_click çıkarılmalı"
    assert_equal 0, Feralin.client.size
  end

  def test_controller_without_consent_produces_no_event
    response = request
    assert_equal 200, response.status, response.body
    assert_nil JSON.parse(response.body).fetch("event_id")
    assert_equal 0, Feralin.client.size
    assert RECEIVED.empty?
  end
end

class RackLintTest < Minitest::Test
  CLIENT = Feralin::Client.new("pk_test_rack_lint_000001", "http://127.0.0.1:9", consent: Feralin::Consent.new, flush_interval: 0)

  def test_middleware_satisfies_rack_spec
    inner = lambda do |env|
      env.fetch(Feralin::Rack::ENV_KEY).track("signup")
      [200, { "content-type" => "text/plain" }, ["ok"]]
    end
    # Lint hem içeriden hem dışarıdan sarar: middleware'in env'e dokunuşu ve yanıtı Rack sözleşmesine göre denetlenir.
    stack = Rack::Lint.new(Feralin::Rack::Middleware.new(Rack::Lint.new(inner), client: CLIENT))
    response = Rack::MockRequest.new(stack).get("/")
    assert_equal 200, response.status
    assert_equal "ok", response.body
    assert_equal 0, CLIENT.size
  end
end

puts "rails #{Rails.version}, rack #{Rack.release}, ruby #{RUBY_VERSION}"
exit(Minitest.run(ARGV) ? 0 : 1)
