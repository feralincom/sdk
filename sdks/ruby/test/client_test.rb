# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < ClientTestCase
  def test_rejects_secret_and_non_pk_keys
    error = assert_raises(Feralin::ConfigurationError) { Feralin::Client.new("sk_live_abcdefgh", @collector.url) }
    assert_match(/gizli anahtar/, error.message)
    error = assert_raises(Feralin::ConfigurationError) { Feralin::Client.new("dev_key_change_me_0001", @collector.url) }
    assert_match(/pk_/, error.message)
    assert_raises(Feralin::ConfigurationError) { Feralin::Client.new("", @collector.url) }
    assert_raises(Feralin::ConfigurationError) { Feralin::Client.new(nil, @collector.url) }
  end

  def test_rejects_bad_collect_url
    ["collect.example.test", "ftp://collect.example.test", "http://", "http://bad host", nil].each do |url|
      assert_raises(Feralin::ConfigurationError, url.inspect) { Feralin::Client.new(TEST_KEY, url) }
    end
  end

  def test_rejects_bad_options
    assert_raises(Feralin::ConfigurationError) { Feralin::Client.new(TEST_KEY, @collector.url, timeout: 0) }
    assert_raises(Feralin::ConfigurationError) { Feralin::Client.new(TEST_KEY, @collector.url, batch_size: "çok") }
    assert_raises(Feralin::ConfigurationError) { Feralin::Client.new(TEST_KEY, @collector.url, transport: "yok") }
    assert_raises(Feralin::ConfigurationError) { Feralin::Client.new(TEST_KEY, @collector.url, consent: true) }
  end

  def test_endpoint_built_from_root_and_key_never_exposed
    client = Feralin::Client.new(TEST_KEY, "https://collect.example.test/", flush_interval: 0)
    @clients << client
    assert_equal "https://collect.example.test/v1/batch", client.status[:endpoint]
    refute_includes client.status.to_s, "pk_"
    refute_includes client.inspect, "pk_"
    refute_includes Feralin::Rack::Tracker.new(client, {}, nil).inspect, "pk_"
  end
end

class TrackFlushTest < ClientTestCase
  def test_track_flush_accepted
    client = make_client
    client.identify("user_42")
    event = client.track(
      "order_completed",
      { order_id: "ord_1", "amount" => 12.5, items: 2 },
      anonymous_id: "anon_1",
      session_id: "ses_1",
      context: Feralin::Context.new(locale: "tr-TR", timezone: "Europe/Istanbul", app: Feralin::AppInfo.new(version: "1.2.3"))
    )
    refute_nil event
    assert_equal "user_42", event["user_id"]
    assert_equal 1, client.size

    result = client.flush
    assert result.ok?, result.error.inspect
    assert_equal [202, 1, 1, 0], [result.status, result.sent, result.accepted, result.rejected]
    assert_equal "01TESTBATCH0000000000000000", result.batch_id
    assert_equal 0, client.size
    assert_equal 1, @collector.count

    request = @collector.request(0)
    assert_equal TEST_KEY, request[:headers]["x-feralin-project-key"]
    assert_equal Feralin::Events.idempotency_key_for([event["event_id"]]), request[:headers]["idempotency-key"]
    assert_equal "application/json", request[:headers]["content-type"]
    assert_equal "feralin-ruby/#{Feralin::VERSION}", request[:headers]["user-agent"]
    assert_match OCCURRED_AT_FORMAT, request[:body]["sent_at"]
    events = request[:body]["events"]
    assert_equal 1, events.length
    wire = events[0]
    assert_wire_event(wire)
    assert_equal "user_42", wire["user_id"]
    assert_equal "anon_1", wire["anonymous_id"]
    assert_equal "ses_1", wire["session_id"]
    assert_equal({ "order_id" => "ord_1", "amount" => 12.5, "items" => 2 }, wire["properties"])
    assert_equal({ "locale" => "tr-TR", "timezone" => "Europe/Istanbul", "app" => { "version" => "1.2.3" } }, wire["context"])
    assert_equal event["event_id"], wire["event_id"]
  end

  def test_optional_fields_omitted
    client = make_client
    event = client.track("signup")
    %w[user_id anonymous_id session_id properties context].each { |key| refute event.key?(key), key }
    client.flush
    assert_wire_event(@collector.request(0)[:body]["events"][0])
  end

  def test_utf8_properties_reach_the_wire_unchanged
    client = make_client
    client.track("signup", { sehir: "İzmir ğüşçö" })
    assert client.flush.ok?
    assert_equal "İzmir ğüşçö", @collector.request(0)[:body]["events"][0]["properties"]["sehir"]
  end

  def test_temporary_failure_keeps_queue_and_idempotency_key
    client = make_client(script: [
                           [503, JSON.generate({ type: "urn:feralin:collect:problem:outbox", title: "Outbox yazılamadı" }), { "Retry-After" => "5" }],
                           [429, JSON.generate({ title: "Çok fazla istek" }), { "Retry-After" => "1" }]
                         ])
    event = client.track("signup")

    result = client.flush
    assert_instance_of Feralin::TemporaryError, result.error
    assert_equal [503, 1, 1], [result.status, result.retained, client.size]
    assert_equal 5.0, client.status[:backoff]

    result = client.flush
    assert_instance_of Feralin::TemporaryError, result.error
    assert_equal [429, 1], [result.status, client.size]
    assert_equal 10.0, client.status[:backoff]

    result = client.flush
    assert result.ok?, result.error.inspect
    assert_equal [202, 0], [result.status, client.size]
    assert_equal 0.0, client.status[:backoff]

    assert_equal 3, @collector.count
    expected = Feralin::Events.idempotency_key_for([event["event_id"]])
    3.times { |index| assert_equal expected, @collector.request(index)[:headers]["idempotency-key"], "istek #{index}" }
  end

  def test_backoff_is_capped
    client = make_client(script: Array.new(7) { [503, "{}", {}] })
    client.track("signup")
    delays = Array.new(7) do
      client.flush
      client.status[:backoff]
    end
    assert_equal [1.0, 2.0, 4.0, 8.0, 16.0, 30.0, 30.0], delays
  end

  def test_idempotency_key_matches_other_sdks
    assert_equal "8f95d6b736d56c98-2",
                 Feralin::Events.idempotency_key_for(%w[01JC0000000000000000000002 01JC0000000000000000000001])
  end

  def test_fr_click_requires_advertising_consent
    client = make_client
    event = client.track("order_completed", { fr_click: "clk", order_id: "o1" })
    assert_equal({ "order_id" => "o1" }, event["properties"])
    event = client.track("order_completed", { "fr_click" => "clk" })
    refute event.key?("properties"), "yalnız fr_click varsa properties tamamen çıkmalı"
    client.set_consent(Feralin::Consent.new(analytics: true, advertising: true))
    event = client.track("order_completed", { fr_click: "clk" })
    assert_equal "clk", event["properties"]["fr_click"]
  end

  def test_pinned_batch_keeps_content_across_retries
    client = make_client(script: [[503, "{}", {}]])
    first = client.track("first_event")
    assert_instance_of Feralin::TemporaryError, client.flush.error
    second = client.track("second_event")
    assert client.flush.ok?
    assert_equal 3, @collector.count
    key = Feralin::Events.idempotency_key_for([first["event_id"]])
    assert_equal key, @collector.request(0)[:headers]["idempotency-key"]
    assert_equal key, @collector.request(1)[:headers]["idempotency-key"]
    assert_equal Feralin::Events.idempotency_key_for([second["event_id"]]), @collector.request(2)[:headers]["idempotency-key"]
  end

  def test_network_error_keeps_queue
    client = make_client
    @collector.close # sunucu kapalı: bağlantı hatası
    client.track("ping")
    result = client.flush
    assert_instance_of Feralin::TemporaryError, result.error
    assert_equal [0, 1], [result.status, client.size]
    assert_equal 1.0, client.status[:backoff]
    client.set_consent(Feralin::Consent.new) # teardown'daki close kapalı sunucuya yeniden denemesin
  end

  def test_unexpected_transport_error_does_not_crash_application
    client = make_client(transport: ->(_url, _body, _headers, _timeout) { raise ArgumentError, "gizli ayrıntı" })
    client.track("ping")
    result = client.flush
    assert_instance_of Feralin::TemporaryError, result.error
    refute_includes result.error.message, "gizli ayrıntı"
    assert_equal 1, client.size
    client.set_consent(Feralin::Consent.new)
  end

  def test_permanent_rejection_drops_events
    logger = MemoryLogger.new
    client = make_client(logger: logger, script: [[400, JSON.generate({ type: "urn:feralin:collect:problem:schema", title: "Şema ihlali", detail: "events[0]" }), {}]])
    client.track("client_valid_but_server_rejects")
    result = client.flush
    assert_instance_of Feralin::RejectedError, result.error
    assert_includes result.error.message, "Şema ihlali"
    assert_equal [400, 1, 0], [result.status, result.rejected, client.size]
    assert client.flush.ok?
    assert_equal 1, @collector.count, "atılan olay yeniden gönderilmemeli"
    logger.lines.each { |line| refute_includes line, "pk_" }
  end

  def test_unauthorized_and_forbidden_drop_queue_without_raising
    [401, 403].each do |status|
      client = make_client(script: [[status, "kapalı", {}]])
      client.track("signup")
      result = client.flush
      assert_instance_of Feralin::RejectedError, result.error
      assert_equal [status, 1, 0], [result.status, result.rejected, client.size]
    end
  end

  def test_consent_gate
    client = make_client(consent: Feralin::Consent.new)
    assert_nil client.track("page_view")
    assert_equal 0, client.size

    client.set_consent(Feralin::Consent.new(analytics: true))
    event = client.track("page_view")
    assert_equal({ "analytics" => true, "advertising" => false, "personalization" => false, "session_replay" => false }, event["consent"])
    assert_equal 1, client.size

    client.set_consent(Feralin::Consent.new)
    assert_equal 0, client.size, "izin geri çekilince kuyruk temizlenmeli"
    assert client.flush.ok?
    assert_equal 0, @collector.count, "izin yokken sunucuya istek gitmemeli"
  end

  def test_only_real_true_counts_as_consent
    consent = Feralin::Consent.new(analytics: "false", advertising: 1)
    assert_equal false, consent.analytics
    assert_equal false, consent.advertising
  end

  def test_per_event_consent_and_explicit_opt_out
    client = make_client(consent: Feralin::Consent.new)
    event = client.track("signup", { fr_click: "clk" }, consent: Feralin::Consent.new(analytics: true))
    assert_equal true, event["consent"]["analytics"]
    refute event.key?("properties")
    assert_nil client.track("signup", consent: Feralin::Consent.new)
    assert_raises(Feralin::InvalidEventError) { client.track("signup", consent: { analytics: true }) }

    # Varsayılan izin yokken temporary hata alan olay korunur: yalnız açık geri çekme kuyruğu siler.
    @collector.script = [[503, "{}", {}]]
    assert_instance_of Feralin::TemporaryError, client.flush.error
    assert_equal 1, client.size
    assert client.flush.ok?

    client.set_consent(Feralin::Consent.new)
    assert_nil client.track("signup", consent: Feralin::Consent.new(analytics: true)), "açık geri çekme olay iznini de geçersiz kılar"
  end

  def test_consent_withdrawn_clears_pinned_batch
    client = make_client(script: [[503, "{}", {}]])
    client.track("signup")
    assert_instance_of Feralin::TemporaryError, client.flush.error
    client.set_consent(Feralin::Consent.new)
    assert client.flush.ok?
    assert_equal 1, @collector.count, "sabitlenmiş batch izin sonrası gönderilmemeli"
  end

  def test_validation
    client = make_client
    ["", "orderCompleted", "1_event", "a" * 101, "has-dash", "satir\nsonu", nil, 42].each do |name|
      assert_raises(Feralin::InvalidEventError, name.inspect) { client.track(name) }
    end
    [{ "1bad" => 1 }, { "bad-key" => 1 }, { "a#{'b' * 64}" => 1 }, { "iyi\nkotu" => 1 }, { 1 => 1 },
     (0..100).to_h { |index| ["k#{index}", index] }].each do |properties|
      assert_raises(Feralin::InvalidEventError, properties.keys.first.inspect) { client.track("ok", properties) }
    end
    assert_raises(Feralin::InvalidEventError) { client.track("ok", "metin") }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", user_id: "u" * 129) }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", user_id: 42) }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", { obj: Object.new }) }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", { zaman: Time.now }) }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", { nan: Float::NAN }) }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", { inf: Float::INFINITY }) }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", { bozuk: "\xFF".dup.force_encoding("UTF-8") }) }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", { ikili: "\xFF".b }) }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", { ic: { 1 => "x" } }) }
    cyclic = []
    cyclic << cyclic
    assert_raises(Feralin::InvalidEventError) { client.track("ok", { dongu: cyclic }) }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", context: { locale: "tr" }) }
    assert_raises(Feralin::InvalidEventError) { client.track("ok", occurred_at: "dün") }
    assert_raises(Feralin::InvalidEventError) { client.identify("u" * 129) }
    assert_raises(Feralin::InvalidEventError) { client.set_consent(true) }
    assert_equal 0, client.size, "geçersiz olaylar kuyruğa girmemeli"

    # Geçersiz ad veya anahtar yanlışlıkla kişisel veri taşıyabilir; istisna iletisi log'a gider, ham değer yazılmaz.
    secret = "eposta@ornek.test"
    refute_includes assert_raises(Feralin::InvalidEventError) { client.track(secret) }.message, secret
    refute_includes assert_raises(Feralin::InvalidEventError) { client.track("ok", { secret => 1 }) }.message, secret

    refute_nil client.track("ok", (0...100).to_h { |index| ["k#{index}", index] })
    refute_nil client.track("fr_system_event_9", { Camel_Key9: "x", ic: { a: [:b, 1, nil, true] } })
    refute_nil client.track(:sembol_olay)
    assert_equal 3, client.size
    assert client.flush.ok?
    wire = @collector.request(0)[:body]["events"]
    assert_equal({ "Camel_Key9" => "x", "ic" => { "a" => ["b", 1, nil, true] } }, wire[1]["properties"])
    assert_equal "sembol_olay", wire[2]["event_name"]
  end

  def test_queue_limit_drops_oldest
    client = make_client(queue_limit: 3, batch_size: 10)
    ids = Array.new(5) { client.track("e")["event_id"] }
    assert_equal [3, 2], [client.size, client.status[:dropped]]
    assert client.flush.ok?
    assert_equal ids[2..], @collector.request(0)[:body]["events"].map { |event| event["event_id"] }
  end

  def test_batch_splitting
    client = make_client(batch_size: 2, queue_limit: 100)
    5.times { client.track("e") }
    result = client.flush
    assert result.ok?, result.error.inspect
    assert_equal [5, 5, 0], [result.sent, result.accepted, client.size]
    assert_equal 3, @collector.count
    first = @collector.request(0)
    assert_equal 2, first[:body]["events"].length
    assert_equal Feralin::Events.idempotency_key_for(first[:body]["events"].map { |event| event["event_id"] }),
                 first[:headers]["idempotency-key"]
    assert_equal 1, @collector.request(2)[:body]["events"].length
  end

  def test_batch_size_is_limited_to_protocol_maximum
    client = make_client(batch_size: 10_000)
    assert_equal Feralin::Client::MAX_BATCH_SIZE, client.instance_variable_get(:@batch_size)
  end

  def test_background_flush
    client = make_client(flush_interval: 0.02)
    client.track("bg")
    assert @collector.wait(3.0), "arka plan gönderici 3 sn içinde istek yapmadı"
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2.0
    sleep(0.005) while client.size.positive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
    assert_equal 0, client.size
  end

  def test_background_flush_wakes_when_batch_is_full
    client = make_client(flush_interval: 3600, batch_size: 2)
    2.times { client.track("bg") }
    assert @collector.wait(3.0), "dolu batch göndericiyi uyandırmadı"
  end

  def test_background_flush_respects_backoff
    client = make_client(script: [[503, JSON.generate({ title: "down" }), {}]], flush_interval: 0.01)
    client.track("bg")
    assert @collector.wait(3.0)
    sleep(0.15)
    assert_equal 1, @collector.count, "geri çekilme sırasında yeniden deneme olmamalı"
    assert_equal 1, client.size
  end

  def test_close_flushes_and_blocks_track
    client = make_client(flush_interval: 3600) # arka plan pratikte hiç çalışmasın
    3.times { client.track("e") }
    result = client.close
    assert result.ok?, result.error.inspect
    assert_equal 1, @collector.count
    assert_equal 3, @collector.request(0)[:body]["events"].length
    assert_equal 0, client.size
    assert client.status[:closed]
    assert_raises(Feralin::ClientClosedError) { client.track("late") }
    assert_raises(Feralin::ClientClosedError) { client.flush }
    assert client.close.ok?, "ikinci close hatasız olmalı"
  end

  def test_close_reports_undelivered
    client = make_client(script: [[503, JSON.generate({ title: "down" }), {}]])
    client.track("e")
    result = client.close(timeout: 1.0)
    assert_instance_of Feralin::TemporaryError, result.error
    assert_equal 1, result.retained
  end

  def test_open_block_flushes
    Feralin::Client.open(TEST_KEY, @collector.url, consent: Feralin::Consent.new(analytics: true), flush_interval: 0) do |client|
      client.track("ctx")
    end
    assert_equal 1, @collector.count
  end

  def test_concurrent_track
    client = make_client(queue_limit: 5000, batch_size: Feralin::Client::MAX_BATCH_SIZE)
    Array.new(8) { Thread.new { 100.times { client.track("c") } } }.each(&:join)
    assert_equal 800, client.size
    result = client.flush
    assert result.ok?, result.error.inspect
    assert_equal [800, 0, 2], [result.accepted, client.size, @collector.count]
    ids = (0...2).flat_map { |index| @collector.request(index)[:body]["events"].map { |event| event["event_id"] } }
    assert_equal ids.length, ids.uniq.length
  end

  def test_occurred_at_uses_injected_clock
    fixed = Time.new(2026, 11, 3, 10, 0, Rational(123_456, 1_000_000), "+03:00")
    client = make_client(now: -> { fixed })
    assert_equal "2026-11-03T07:00:00.123Z", client.track("clock")["occurred_at"]
    explicit = Time.utc(2026, 1, 2, 3, 4, 5)
    assert_equal "2026-01-02T03:04:05.000Z", client.track("clock", occurred_at: explicit)["occurred_at"]
  end
end

# Puma ve Unicorn çatallanması. Windows'ta Process.fork yoktur; orada yalnız pid değişimi taklit edilen test koşar.
class ForkSafetyTest < ClientTestCase
  def test_child_process_starts_with_empty_queue_and_own_sender
    client = make_client(flush_interval: 0.02)
    # Üst süreçte kuyruktaki olay yavruda bir daha gönderilmemeli: göndericiyi önce durdurup olayı bekletiyoruz.
    client.send(:stop_thread, 1)
    inherited = client.track("inherited")
    old_pid = Process.pid
    client.define_singleton_method(:current_pid) { old_pid + 1 }

    event = client.track("from_child")
    assert_equal 1, client.size, "miras kalan olay yavruda tutulmamalı"
    refute_equal inherited["event_id"], event["event_id"]
    assert client.instance_variable_get(:@thread)&.alive?, "yavruda gönderici yeniden başlamalı"
    assert @collector.wait(3.0)
    ids = @collector.request(0)[:body]["events"].map { |wire| wire["event_id"] }
    assert_equal [event["event_id"]], ids
  end

  def test_closed_client_does_not_restart_sender_after_fork
    client = make_client(flush_interval: 3600)
    client.close
    old_pid = Process.pid
    client.define_singleton_method(:current_pid) { old_pid + 1 }
    assert_equal 0, client.size
    assert_nil client.instance_variable_get(:@thread)
  end

  def test_real_fork_sends_only_child_events
    skip "Process.fork bu platformda yok" unless Process.respond_to?(:fork)

    client = make_client(flush_interval: 0)
    client.track("parent_event")
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      event = client.track("child_event")
      result = client.flush
      writer.write(JSON.generate({ id: event["event_id"], ok: result.ok?, sent: result.sent }))
      writer.close
      exit!(0)
    end
    writer.close
    child = JSON.parse(reader.read)
    Process.wait(pid)
    assert_equal [true, 1], [child["ok"], child["sent"]]
    assert_equal [child["id"]], @collector.request(0)[:body]["events"].map { |wire| wire["event_id"] }
    assert_equal 1, client.size, "üst süreç kendi olayını korumalı"
  end
end
