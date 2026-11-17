# frozen_string_literal: true

require "test_helper"

# Rack sözleşmesi elle kurulan env ile sınanır; gerçek Rack::Lint ve Rails test/rails/rails_integration.rb içindedir.
class RackMiddlewareTest < ClientTestCase
  CONSENT_FROM_HEADER = ->(env) { Feralin::Consent.new(analytics: env["HTTP_X_ANALITIK"] == "1", advertising: env["HTTP_X_REKLAM"] == "1") }

  def teardown
    Feralin.client = nil
    super
  end

  def stack(client: nil, consent: CONSENT_FROM_HEADER, **options, &handler)
    Feralin::Rack::Middleware.new(handler, client: client, consent: consent, logger: MemoryLogger.new, **options)
  end

  def ok(status = 200)
    [status, { "content-type" => "text/plain" }, ["ok"]]
  end

  def test_response_is_passed_through_untouched
    response = ok(201)
    app = stack(client: make_client(consent: Feralin::Consent.new)) { |_env| response }
    assert_same response, app.call({})
  end

  def test_requests_have_separate_consent_and_identity
    client = make_client(consent: Feralin::Consent.new)
    events = {}
    app = stack(client: client) do |env|
      tracker = env[Feralin::Rack::ENV_KEY]
      tracker.identify(env["HTTP_X_KULLANICI"])
      events[env["HTTP_X_KULLANICI"]] = tracker.track("order_completed", { fr_click: "clk" })
      ok
    end

    app.call({ "HTTP_X_ANALITIK" => "1", "HTTP_X_REKLAM" => "1", "HTTP_X_KULLANICI" => "user_a" })
    app.call({ "HTTP_X_ANALITIK" => "1", "HTTP_X_KULLANICI" => "user_b" })
    app.call({ "HTTP_X_KULLANICI" => "user_c" })

    assert_equal "user_a", events["user_a"]["user_id"]
    assert_equal "clk", events["user_a"]["properties"]["fr_click"]
    assert_equal "user_b", events["user_b"]["user_id"]
    refute events["user_b"].key?("properties"), "reklam izni olmayan istekte fr_click çıkarılmalı"
    assert_nil events["user_c"], "izinsiz istekte olay üretilmemeli"
    assert_nil client.status[:user_id], "istek kimliği paylaşılan istemciye sızmamalı"
    assert_equal 2, client.size
  end

  def test_concurrent_requests_do_not_mix_identity
    client = make_client(consent: Feralin::Consent.new(analytics: true), queue_limit: 1000)
    wrong = Queue.new
    app = stack(client: client, consent: nil) do |env|
      tracker = env[Feralin::Rack::ENV_KEY]
      user = env["HTTP_X_KULLANICI"]
      tracker.identify(user)
      Thread.pass
      wrong << user unless tracker.track("e")["user_id"] == user
      ok
    end
    Array.new(8) { |index| Thread.new { 25.times { app.call({ "HTTP_X_KULLANICI" => "user_#{index}" }) } } }.each(&:join)
    assert wrong.empty?
    assert_equal 200, client.size
  end

  def test_without_resolver_client_consent_applies
    client = make_client(consent: Feralin::Consent.new(analytics: true))
    event = nil
    app = stack(client: client, consent: nil) do |env|
      event = env[Feralin::Rack::ENV_KEY].track("signup")
      ok
    end
    app.call({})
    refute_nil event
  end

  def test_resolver_failures_mean_no_consent
    client = make_client(consent: Feralin::Consent.new(analytics: true))
    logger = MemoryLogger.new
    [->(_env) { raise "kullanıcı@ornek.test" }, ->(_env) { true }, ->(_env) {}].each do |resolver|
      event = :isaret
      app = Feralin::Rack::Middleware.new(lambda { |env|
        event = env[Feralin::Rack::ENV_KEY].track("signup")
        [200, {}, []]
      }, client: client, consent: resolver, logger: logger)
      app.call({})
      assert_nil event, "izin çözülemezse istemcinin varsayılan izni kullanılmamalı"
    end
    assert_equal 0, client.size
    refute(logger.lines.any? { |line| line.include?("ornek.test") }, "hata iletisi günlüğe yazılmamalı")
  end

  def test_resolver_runs_once_and_only_when_needed
    client = make_client
    calls = 0
    resolver = lambda do |_env|
      calls += 1
      Feralin::Consent.new(analytics: true)
    end
    idle = stack(client: client, consent: resolver) { |_env| ok }
    idle.call({})
    assert_equal 0, calls

    busy = stack(client: client, consent: resolver) do |env|
      2.times { env[Feralin::Rack::ENV_KEY].track("e") }
      ok
    end
    busy.call({})
    assert_equal 1, calls
  end

  def test_tracker_set_consent_overrides_for_this_request
    client = make_client(consent: Feralin::Consent.new)
    event = nil
    app = stack(client: client) do |env|
      tracker = env[Feralin::Rack::ENV_KEY]
      tracker.set_consent(Feralin::Consent.new(analytics: true))
      event = tracker.track("consent_given")
      assert_raises(Feralin::InvalidEventError) { tracker.set_consent(:evet) }
      ok
    end
    app.call({})
    refute_nil event
  end

  def test_global_client_is_used_when_none_given
    client = make_client
    Feralin.client = client
    app = stack(consent: nil) do |env|
      env[Feralin::Rack::ENV_KEY].track("signup")
      ok
    end
    app.call({})
    assert_equal 1, client.size
  end

  def test_missing_client_is_silent_noop
    tracker = nil
    app = stack(consent: nil) do |env|
      tracker = env[Feralin::Rack::ENV_KEY]
      assert_nil tracker.track("signup")
      ok
    end
    assert_equal 200, app.call({})[0]
    assert_equal 0, tracker.flush.sent
  end

  def test_flush_after_request_inline_and_on_error
    client = make_client
    app = stack(client: client, consent: nil, flush_after_request: true) do |env|
      env[Feralin::Rack::ENV_KEY].track("signup")
      raise ArgumentError, "uygulama hatası" if env["HTTP_X_PATLA"]

      ok
    end
    app.call({})
    assert_equal 1, @collector.count
    assert_raises(ArgumentError) { app.call({ "HTTP_X_PATLA" => "1" }) }
    assert_equal 2, @collector.count, "uygulama hatasında da gönderim denenmeli ve hata korunmalı"
  end

  def test_flush_after_request_uses_server_hooks
    %w[rack.response_finished rack.after_reply].each do |hook|
      client = make_client
      before = @collector.count
      app = stack(client: client, consent: nil, flush_after_request: true) do |env|
        env[Feralin::Rack::ENV_KEY].track("signup")
        ok
      end
      callbacks = []
      app.call({ hook => callbacks })
      assert_equal before, @collector.count, "#{hook}: yanıttan önce gönderilmemeli"
      assert_equal 1, callbacks.length
      callbacks.first.call({}, 200, {}, nil)
      assert_equal before + 1, @collector.count
    end
  end

  def test_flush_after_request_survives_closed_client
    client = make_client
    client.close
    app = stack(client: client, consent: nil, flush_after_request: true) { |_env| ok }
    assert_equal 200, app.call({})[0]
  end

  def test_rejects_non_callable_resolver
    assert_raises(Feralin::ConfigurationError) { Feralin::Rack::Middleware.new(->(_env) {}, consent: true) }
  end

  def test_rails_is_not_loaded_by_the_gem
    refute defined?(::Rails), "Rails bu süreçte yüklenmemeli"
    refute defined?(Feralin::Railtie), "Rails yoksa Railtie tanımlanmamalı"
  end
end
