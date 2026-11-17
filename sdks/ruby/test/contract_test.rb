# frozen_string_literal: true

require "test_helper"

# Gelir (feralin_purchase), kimlik (fr_group, fr_user_properties) ve hata (fr_error) sözleşmeleri.
class RevenueContractTest < ClientTestCase
  def test_revenue_contract_never_sends_verified
    client = make_client
    event = client.track_revenue(
      "GPA.1234-5678", 4999, "TRY",
      product_id: "pro_monthly", quantity: 2, purchase_type: :subscription_start,
      receipt: { provider: "google", token: "tok_1" },
      properties: { verified: true, "receipt_provider" => "apple", amount_minor: 1, plan: "pro" },
      user_id: "u1"
    )
    assert_equal "feralin_purchase", event["event_name"]
    assert_equal "u1", event["user_id"]
    assert_equal(
      { "transaction_id" => "GPA.1234-5678", "amount_minor" => 4999, "currency" => "TRY", "quantity" => 2,
        "purchase_type" => "subscription_start", "product_id" => "pro_monthly",
        "receipt" => { "provider" => "google", "token" => "tok_1" }, "plan" => "pro" },
      event["properties"]
    )
    assert client.flush.ok?
    body = JSON.generate(@collector.request(0)[:body])
    refute_includes body, "verified"

    cancel = client.track_revenue("t2", 0, "USD", purchase_type: "subscription_cancel")
    assert_equal 1, cancel["properties"]["quantity"]
    assert_equal "purchase", client.track_revenue("t3", 100, "EUR")["properties"]["purchase_type"]
  end

  def test_invalid_revenue_raises
    client = make_client
    invalid = [
      ["", 1, "TRY", {}], ["x" * 129, 1, "TRY", {}], [nil, 1, "TRY", {}],
      ["t", 49.99, "TRY", {}], ["t", "4999", "TRY", {}], ["t", -1, "TRY", {}], ["t", Feralin::Revenue::MAX_AMOUNT_MINOR + 1, "TRY", {}],
      ["t", 1, "try", {}], ["t", 1, "TRYY", {}],
      ["t", 1, "TRY", { product_id: "" }], ["t", 1, "TRY", { quantity: -1 }], ["t", 1, "TRY", { quantity: 100_001 }],
      ["t", 1, "TRY", { quantity: 1.5 }], ["t", 1, "TRY", { purchase_type: "refund" }],
      ["t", 1, "TRY", { purchase_type: "subscription_cancel" }],
      ["t", 1, "TRY", { receipt: { provider: "paypal", token: "t" } }], ["t", 1, "TRY", { receipt: { provider: "apple", token: "" } }],
      ["t", 1, "TRY", { receipt: "apple" }], ["t", 1, "TRY", { properties: "x" }]
    ]
    invalid.each do |id, amount, currency, extra|
      assert_raises(Feralin::InvalidEventError, [id, amount, currency, extra].inspect) do
        client.track_revenue(id, amount, currency, **extra)
      end
    end
    assert_equal 0, client.size
    refute_nil client.track_revenue("t", Feralin::Revenue::MAX_AMOUNT_MINOR, "TRY", quantity: 100_000)
  end

  def test_revenue_without_consent_is_nil
    client = make_client(consent: Feralin::Consent.new)
    assert_nil client.track_revenue("t", 1, "TRY")
  end
end

class ProfileContractTest < ClientTestCase
  def test_group_and_user_properties
    client = make_client
    event = client.group("acme-team", { plan: "team", email: "x@y.co", group_id: "baska", seats: 12 }, user_id: "u1")
    assert_equal "fr_group", event["event_name"]
    assert_equal({ "plan" => "team", "seats" => 12, "group_id" => "acme-team" }, event["properties"])
    ["", "   ", "a@b", "g" * 129, "x\ny", nil, 5].each { |bad| assert_nil client.group(bad), bad.inspect }
    refute_nil client.group("g" * 128)

    props = { plan: "pro", userEmail: "a", phoneNumber: "1", firstName: "Ali", verified: true, bio: "a@b.co",
              score: Float::NAN, long: "x" * 257, nested: { a: 1 }, beta: true }
    user = client.set_user_properties(props)
    assert_equal "fr_user_properties", user["event_name"]
    assert_equal({ "plan" => "pro", "beta" => true }, user["properties"])
    assert_nil client.set_user_properties({ email: "x" })

    many = (0...60).to_h { |i| ["k#{i}", i] }
    assert_equal Feralin::Profile::MAX_PROPERTIES, client.set_user_properties(many)["properties"].length
  end

  def test_pii_key_rule_matches_other_sdks
    %w[email userEmail email_address phone phoneNumber mobile ip userIP ipv4 ip_address firstName last_name fullName name
       userName displayName address tckn birthDate dob].each { |key| assert Feralin::Profile.pii_like_key?(key), key }
    %w[plan tier zip_code company_size nameSpace shipping_method tipping].each { |key| refute Feralin::Profile.pii_like_key?(key), key }
  end
end

class ErrorContractTest < ClientTestCase
  ALLOWED = %w[error_type message fingerprint top_frame frame_count app_version handled fatal origin frames].freeze

  def failing_call(message)
    raise ArgumentError, message
  rescue ArgumentError => e
    e
  end

  def test_error_event_contract_without_raw_stack_or_pii
    client = make_client(app_version: "1.4.2")
    error = failing_call("Sipariş 1234567 başarısız: ali@example.com https://shop.test/o?token=abc 9f8e7d6c5b4a39281706f5e4d3c2b1a0")
    event = client.capture_error(error, user_id: "u1")
    assert_equal "fr_error", event["event_name"]
    assert_equal "u1", event["user_id"]
    props = event["properties"]
    assert_equal "ArgumentError", props["error_type"]
    assert_equal "Sipariş [num] başarısız: [email] [url] [token]", props["message"]
    assert_match(/\A[0-9a-f]{32}\z/, props["fingerprint"])
    assert_match(/failing_call@contract_test\.rb\z/, props["top_frame"])
    assert_operator props["frame_count"], :>, 0
    assert_equal "1.4.2", props["app_version"]
    assert_equal [true, false, "handled"], [props["handled"], props["fatal"], props["origin"]]
    assert_empty props.keys - ALLOWED
    frames = props["frames"]
    assert_includes 1..5, frames.length
    frames.each do |frame|
      assert_match(/\A[A-Za-z0-9._~-]{1,128}\z/, frame["file"])
      assert_operator frame["line"], :>=, 1
      assert_equal 0, frame["column"]
    end
    assert_equal "contract_test.rb", frames.first["file"]
    assert_equal "failing_call", frames.first["function"]
    assert client.flush.ok?
    body = JSON.generate(@collector.request(0)[:body])
    ["ali@example.com", "shop.test", "token=abc", __dir__, "/gems/"].each { |leak| refute_includes body, leak }
  end

  def test_fingerprint_is_stable_and_ignores_message
    first = Feralin::ErrorEvent.properties(failing_call("kullanıcı 1"), "handled", false)["fingerprint"]
    second = Feralin::ErrorEvent.properties(failing_call("kullanıcı 2"), "handled", false)["fingerprint"]
    assert_equal first, second
    refute_equal first, Feralin::ErrorEvent.properties(RuntimeError.new("x"), "handled", false)["fingerprint"]
    # Fırlatılmamış hata: çerçeve yok, parmak izi rakamları normalize edilmiş mesajdan.
    bare = Feralin::ErrorEvent.properties(RuntimeError.new("kod 42"), "manual", false)
    assert_equal bare["fingerprint"], Feralin::ErrorEvent.properties(RuntimeError.new("kod 43"), "manual", false)["fingerprint"]
    refute bare.key?("frames")
    assert_equal 0, bare["frame_count"]
  end

  def test_limiter_per_fingerprint_and_window
    now = Time.at(1_700_000_000)
    client = make_client(now: -> { now })
    error = failing_call("aynı")
    accepted = Array.new(5) { client.capture_error(error) }.compact.length
    assert_equal 3, accepted
    now += 60
    refute_nil client.capture_error(error)

    limiter = Feralin::ErrorLimiter.new
    assert_equal 20, (0...30).count { |i| limiter.allow?("fp#{i}", 1.0, 0.0) }
    assert limiter.allow?("fp_yeni", 61.0, 0.0)
    refute Feralin::ErrorLimiter.new(sample_rate: 0.5).allow?("fp", 0.0, 0.9)
  end

  def test_capture_error_never_raises_and_respects_consent
    denied = make_client(consent: Feralin::Consent.new)
    assert_nil denied.capture_error(failing_call("x"))
    client = make_client
    assert_nil client.capture_error("hata değil")
    assert_nil client.capture_error(RuntimeError.new("x"), origin: "window_onerror")
    fatal = client.capture_error(RuntimeError.new("x"), origin: :uncaught_exception)
    assert_equal [false, true, "uncaught_exception"], fatal["properties"].values_at("handled", "fatal", "origin")
    assert_nil client.capture_error(RuntimeError.new("y"), user_id: "u" * 129)
    client.close(timeout: 1.0)
    assert_nil client.capture_error(failing_call("kapalı"))
  end

  def test_scrub_matches_collector
    assert_equal "[email] yazdı", Feralin::ErrorEvent.scrub("ali.veli@example.com yazdı")
    assert_equal "bkz [url]", Feralin::ErrorEvent.scrub("bkz   https://x.test/a?b=c\n")
    assert_equal "kimlik [id]", Feralin::ErrorEvent.scrub("kimlik 123e4567-e89b-12d3-a456-426614174000")
    assert_equal "sürüm 1.4.2 tel [num]", Feralin::ErrorEvent.scrub("sürüm 1.4.2 tel +90 (555) 123-4567")
    assert_equal "UnsupportedOperationExceptionHandler", Feralin::ErrorEvent.scrub("UnsupportedOperationExceptionHandler")
    assert_equal 200, Feralin::ErrorEvent.scrub("ğ" * 500).length
    assert_equal "bozuk ?", Feralin::ErrorEvent.scrub("bozuk \xFF".dup.force_encoding(Encoding::UTF_8))
  end

  def test_rack_tracker_passes_request_identity_and_consent
    client = make_client(consent: Feralin::Consent.new)
    resolver = ->(_env) { Feralin::Consent.new(analytics: true) }
    tracker = Feralin::Rack::Tracker.new(client, {}, resolver)
    tracker.identify("user_42")
    assert_equal "user_42", tracker.track_revenue("ord_1", 4999, "TRY")["user_id"]
    assert_equal "fr_group", tracker.group("acme", { plan: "team" })["event_name"]
    assert_equal({ "plan" => "pro" }, tracker.set_user_properties({ plan: "pro" })["properties"])
    assert_equal "user_42", tracker.capture_error(failing_call("x"))["user_id"]
    assert_nil Feralin::Rack::Tracker.new(nil, {}, nil).capture_error(failing_call("x"))
  end
end
