// Tel biçimi test vektörleri. sdks/cpp ve sdks/unreal testleri bu dosyayı aynen içerir; iki SDK'nın aynı baytları ürettiğini sınar.
// Çağıran dosya TEST_CASE, ASSERT_TRUE, ASSERT_EQ makrolarını tanımlar ve feralin::wire görünür olmalıdır.
// SDK kimliği (name, version, platform) WIRE_TEST_IDENTITY ile verilir.

using feralin::wire::Consent;
using feralin::wire::EventCore;
using feralin::wire::TrackOptions;
using feralin::wire::TrackOutcome;
using feralin::wire::Value;

namespace wire_cases {

inline void zero_fill(unsigned char* buffer, std::size_t length) {
  for (std::size_t i = 0; i < length; ++i) buffer[i] = 0;
}

inline Consent analytics_only() {
  Consent consent;
  consent.analytics = true;
  return consent;
}

inline EventCore make_core(const Consent& consent, int batch_size = 100, int queue_limit = 1000) {
  return EventCore(WIRE_TEST_IDENTITY, batch_size, queue_limit, consent);
}

constexpr std::int64_t kNow = 1793700000123;

}  // namespace wire_cases

TEST_CASE(wire_idempotency_key_matches_other_sdks) {
  ASSERT_EQ(feralin::wire::idempotency_key_for({"01JC0000000000000000000002", "01JC0000000000000000000001"}), std::string("8f95d6b736d56c98-2"));
}

TEST_CASE(wire_format_time) {
  ASSERT_EQ(feralin::wire::format_time(0), std::string("1970-01-01T00:00:00.000Z"));
  ASSERT_EQ(feralin::wire::format_time(1793690400123), std::string("2026-11-03T07:20:00.123Z"));
  ASSERT_EQ(feralin::wire::format_time(951782400000), std::string("2000-02-29T00:00:00.000Z"));
  ASSERT_EQ(feralin::wire::format_time(feralin::wire::kMaxTimestampMs), std::string("9999-12-31T23:59:59.999Z"));
  ASSERT_EQ(feralin::wire::format_time(-1), std::string("1969-12-31T23:59:59.999Z"));
}

TEST_CASE(wire_ulid_shape_and_monotonic) {
  feralin::wire::UlidGenerator generator;
  const std::string first = generator.next(1793700000123, wire_cases::zero_fill);
  ASSERT_TRUE(feralin::wire::is_ulid(first));
  ASSERT_EQ(first.size(), std::size_t{26});
  // Aynı milisaniye ve saat geri gidişi: yine artan sıra.
  const std::string second = generator.next(1793700000123, wire_cases::zero_fill);
  const std::string third = generator.next(1793699999000, wire_cases::zero_fill);
  ASSERT_TRUE(first < second);
  ASSERT_TRUE(second < third);
  ASSERT_EQ(first.substr(0, 10), second.substr(0, 10));
  ASSERT_TRUE(!feralin::wire::is_ulid("8ZZZZZZZZZZZZZZZZZZZZZZZZZ"));
  ASSERT_TRUE(!feralin::wire::is_ulid("01JC000000000000000000000I"));
  ASSERT_TRUE(!feralin::wire::is_ulid("01JC"));
}

TEST_CASE(wire_json_string_escapes) {
  std::string out;
  ASSERT_TRUE(feralin::wire::append_json_string(out, "a\"b\\c\n\t\r\b\f\x01 şİ"));
  ASSERT_EQ(out, std::string("\"a\\\"b\\\\c\\n\\t\\r\\b\\f\\u0001 şİ\""));
}

TEST_CASE(wire_json_rejects_bad_text) {
  std::string out;
  ASSERT_TRUE(!feralin::wire::append_json_string(out, "\xC3"));          // yarım karakter
  ASSERT_TRUE(!feralin::wire::append_json_string(out, "\xC0\xAF"));      // uzun kodlama
  ASSERT_TRUE(!feralin::wire::append_json_string(out, "\xED\xA0\x80"));  // vekil
  ASSERT_TRUE(!feralin::wire::append_json_string(out, "\xF4\x90\x80\x80"));  // U+10FFFF üstü
  ASSERT_TRUE(!feralin::wire::append_json_string(out, std::string("a\0b", 3)));
}

TEST_CASE(wire_json_numbers) {
  const auto write = [](const Value& value) {
    std::string out;
    if (!feralin::wire::append_json(out, value)) return std::string("<red>");
    return out;
  };
  ASSERT_EQ(write(Value(12.5)), std::string("12.5"));
  ASSERT_EQ(write(Value(0.1)), std::string("0.1"));
  ASSERT_EQ(write(Value(249.9)), std::string("249.9"));
  ASSERT_EQ(write(Value(2)), std::string("2"));
  ASSERT_EQ(write(Value(static_cast<std::int64_t>(-9007199254740993))), std::string("-9007199254740993"));
  ASSERT_EQ(write(Value(std::numeric_limits<double>::quiet_NaN())), std::string("<red>"));
  ASSERT_EQ(write(Value(std::numeric_limits<double>::infinity())), std::string("<red>"));
  // Kısa gösterim geri okununca aynı sayıyı vermeli.
  Value round_trip;
  ASSERT_TRUE(feralin::wire::parse_json(write(Value(1.7976931348623157e308)), round_trip));
  ASSERT_TRUE(round_trip.as_double() == 1.7976931348623157e308);
}

TEST_CASE(wire_json_parser) {
  Value parsed;
  ASSERT_TRUE(feralin::wire::parse_json(" {\"a\":[1,-2,3.5,true,false,null,\"x\\u015f\\ud83d\\ude00\\n\"],\"b\":{\"c\":\"d\"}} ", parsed));
  ASSERT_TRUE(parsed.is_object());
  const Value* a = parsed.find("a");
  ASSERT_TRUE(a != nullptr && a->is_array());
  ASSERT_EQ(a->size(), std::size_t{7});
  ASSERT_EQ(a->at(1).as_int(), std::int64_t{-2});
  ASSERT_TRUE(a->at(2).as_double() == 3.5);
  ASSERT_EQ(a->at(6).as_string(), std::string("xş\xF0\x9F\x98\x80\n"));
  ASSERT_EQ(parsed.find("b")->find("c")->as_string(), std::string("d"));

  Value ignored;
  for (const char* bad : {"", "{", "[1,]", "{\"a\":}", "01", "1.", "+1", "tru", "\"\\ud800\"", "\"\\x\"", "\"a\nb\"", "{\"a\":1}x", "1e999"}) {
    ASSERT_TRUE(!feralin::wire::parse_json(bad, ignored));
  }
  std::string deep;
  for (int i = 0; i < 100; ++i) deep += "[";
  for (int i = 0; i < 100; ++i) deep += "]";
  ASSERT_TRUE(!feralin::wire::parse_json(deep, ignored));
  // int64 aralığı dışı tam sayı kesirli sayıya düşer, sessizce taşmaz.
  ASSERT_TRUE(feralin::wire::parse_json("-9223372036854775808", parsed));
  ASSERT_TRUE(parsed.is_integer());
  ASSERT_TRUE(feralin::wire::parse_json("9223372036854775808", parsed));
  ASSERT_TRUE(!parsed.is_integer());
}

TEST_CASE(wire_project_key_and_endpoint) {
  std::string key;
  ASSERT_TRUE(!feralin::wire::normalize_project_key("  pk_live_abcdef  ", key).failed());
  ASSERT_EQ(key, std::string("pk_live_abcdef"));
  const auto secret = feralin::wire::normalize_project_key("sk_live_abcdefgh", key);
  ASSERT_TRUE(secret.code == feralin::wire::ErrorCode::configuration);
  ASSERT_TRUE(secret.message.find("sk_live_abcdefgh") == std::string::npos);
  ASSERT_TRUE(feralin::wire::normalize_project_key("dev_key_change_me", key).failed());
  ASSERT_TRUE(feralin::wire::normalize_project_key("pk_", key).failed());
  ASSERT_TRUE(feralin::wire::normalize_project_key("pk_abc\r\nX: y", key).failed());

  std::string endpoint;
  ASSERT_TRUE(!feralin::wire::collect_endpoint("https://collect.example.test/", endpoint).failed());
  ASSERT_EQ(endpoint, std::string("https://collect.example.test/v1/batch"));
  ASSERT_TRUE(!feralin::wire::collect_endpoint("HTTP://127.0.0.1:4713", endpoint).failed());
  ASSERT_EQ(endpoint, std::string("HTTP://127.0.0.1:4713/v1/batch"));
  for (const char* bad : {"", "collect.example.test", "ftp://collect.example.test", "https://", "http:///x", "http://a b"}) {
    ASSERT_TRUE(feralin::wire::collect_endpoint(bad, endpoint).failed());
  }
}

TEST_CASE(wire_consent_gate_produces_nothing) {
  EventCore core = wire_cases::make_core(Consent());
  const TrackOutcome outcome = core.track("page_view", Value(), TrackOptions(), wire_cases::kNow, wire_cases::zero_fill);
  ASSERT_TRUE(!outcome.produced && !outcome.error.failed());
  ASSERT_EQ(core.queued(), std::size_t{0});
  ASSERT_TRUE(core.peek().empty());
}

TEST_CASE(wire_event_bytes_are_exact) {
  EventCore core = wire_cases::make_core(wire_cases::analytics_only());
  Value properties = Value::make_object();
  properties.set("order_id", "ord_1");
  properties.set("amount", 12.5);
  properties.set("items", 2);
  TrackOptions options;
  options.user_id = "user_42";
  options.anonymous_id = "anon_1";
  options.session_id = "ses_1";
  options.occurred_at_ms = 1793690400123;
  feralin::wire::Context context;
  context.locale = "tr-TR";
  context.screen = std::make_pair(1920, 1080);
  context.app_version = "1.2.3";
  options.context = context;
  const TrackOutcome outcome = core.track("order_completed", properties, options, wire_cases::kNow, wire_cases::zero_fill);
  ASSERT_TRUE(outcome.produced);
  const feralin::wire::SdkIdentity identity = WIRE_TEST_IDENTITY;
  const std::string expected = "{\"event_id\":\"" + outcome.event_id +
                               "\",\"event_name\":\"order_completed\",\"occurred_at\":\"2026-11-03T07:20:00.123Z\",\"platform\":\"" + identity.platform +
                               "\",\"schema_version\":1,\"sdk\":{\"name\":\"" + identity.name + "\",\"version\":\"" + identity.version +
                               "\"},\"consent\":{\"analytics\":true,\"advertising\":false,\"personalization\":false,\"session_replay\":false}"
                               ",\"anonymous_id\":\"anon_1\",\"user_id\":\"user_42\",\"session_id\":\"ses_1\""
                               ",\"properties\":{\"order_id\":\"ord_1\",\"amount\":12.5,\"items\":2}"
                               ",\"context\":{\"locale\":\"tr-TR\",\"screen\":{\"width\":1920,\"height\":1080},\"app\":{\"version\":\"1.2.3\"}}}";
  ASSERT_EQ(outcome.event_json, expected);
  // İstemciden gönderilmemesi gereken alanlar.
  for (const char* forbidden : {"tenant_id", "project_id", "verified", "source_ip"}) {
    ASSERT_TRUE(outcome.event_json.find(forbidden) == std::string::npos);
  }
  const feralin::wire::Batch batch = core.peek();
  const std::string body = EventCore::batch_body(batch, 0);
  ASSERT_EQ(body, "{\"sent_at\":\"1970-01-01T00:00:00.000Z\",\"events\":[" + expected + "]}");
  ASSERT_EQ(EventCore::batch_key(batch), feralin::wire::idempotency_key_for({outcome.event_id}));
}

TEST_CASE(wire_fr_click_requires_advertising) {
  Value properties = Value::make_object();
  properties.set("fr_click", "clk");
  EventCore core = wire_cases::make_core(wire_cases::analytics_only());
  TrackOutcome outcome = core.track("order_completed", properties, TrackOptions(), wire_cases::kNow, wire_cases::zero_fill);
  ASSERT_TRUE(outcome.event_json.find("fr_click") == std::string::npos);
  ASSERT_TRUE(outcome.event_json.find("\"properties\"") == std::string::npos);  // boş kaldıysa alan yazılmaz
  Consent advertising = wire_cases::analytics_only();
  advertising.advertising = true;
  core.set_consent(advertising);
  outcome = core.track("order_completed", properties, TrackOptions(), wire_cases::kNow, wire_cases::zero_fill);
  ASSERT_TRUE(outcome.event_json.find("\"fr_click\":\"clk\"") != std::string::npos);
  ASSERT_TRUE(outcome.event_json.find("\"advertising\":true") != std::string::npos);
}

TEST_CASE(wire_validation) {
  EventCore core = wire_cases::make_core(wire_cases::analytics_only());
  const auto invalid = [&core](const std::string& name, const Value& properties, const TrackOptions& options) {
    return core.track(name, properties, options, wire_cases::kNow, wire_cases::zero_fill).error.code == feralin::wire::ErrorCode::invalid_event;
  };
  for (const std::string& name : {std::string(), std::string("orderCompleted"), std::string("1_event"), std::string(101, 'a'), std::string("has-dash")}) {
    ASSERT_TRUE(invalid(name, Value(), TrackOptions()));
  }
  const auto one = [](const std::string& key, Value value) {
    Value out = Value::make_object();
    out.set(key, std::move(value));
    return out;
  };
  ASSERT_TRUE(invalid("ok", one("1bad", 1), TrackOptions()));
  ASSERT_TRUE(invalid("ok", one("bad-key", 1), TrackOptions()));
  ASSERT_TRUE(invalid("ok", one("a" + std::string(64, 'b'), 1), TrackOptions()));
  ASSERT_TRUE(invalid("ok", one("nan", std::numeric_limits<double>::quiet_NaN()), TrackOptions()));
  ASSERT_TRUE(invalid("ok", one("bad_utf8", std::string("\xC3")), TrackOptions()));
  ASSERT_TRUE(invalid("ok", Value("metin"), TrackOptions()));
  Value too_many = Value::make_object();
  for (int i = 0; i < 101; ++i) too_many.set("k" + std::to_string(i), i);
  ASSERT_TRUE(invalid("ok", too_many, TrackOptions()));
  TrackOptions options;
  options.user_id = std::string(129, 'u');
  ASSERT_TRUE(invalid("ok", Value(), options));
  options = TrackOptions();
  options.occurred_at_ms = -1;
  ASSERT_TRUE(invalid("ok", Value(), options));
  options = TrackOptions();
  feralin::wire::Context context;
  context.locale = std::string(17, 'x');
  options.context = context;
  ASSERT_TRUE(invalid("ok", Value(), options));
  ASSERT_TRUE(core.identify(std::string(129, 'u')).failed());
  ASSERT_EQ(core.queued(), std::size_t{0});  // geçersiz olay kuyruğa girmez

  // Sınır değerler geçerli; 128 karakter kod noktası sayılır, bayt değil.
  std::string turkish;
  for (int i = 0; i < 128; ++i) turkish += "ş";
  options = TrackOptions();
  options.user_id = turkish;
  ASSERT_TRUE(core.track("ok", Value(), options, wire_cases::kNow, wire_cases::zero_fill).produced);
  Value hundred = Value::make_object();
  for (int i = 0; i < 100; ++i) hundred.set("k" + std::to_string(i), i);
  ASSERT_TRUE(core.track("fr_system_event_9", hundred, TrackOptions(), wire_cases::kNow, wire_cases::zero_fill).produced);
}

TEST_CASE(wire_queue_limit_drops_oldest) {
  EventCore core = wire_cases::make_core(wire_cases::analytics_only(), 10, 3);
  std::vector<std::string> ids;
  for (int i = 0; i < 5; ++i) ids.push_back(core.track("e", Value(), TrackOptions(), wire_cases::kNow, wire_cases::zero_fill).event_id);
  ASSERT_EQ(core.queued(), std::size_t{3});
  ASSERT_EQ(core.dropped(), std::int64_t{2});
  const feralin::wire::Batch batch = core.peek();
  ASSERT_EQ(batch.size(), std::size_t{3});
  ASSERT_EQ(batch[0].id, ids[2]);
}

TEST_CASE(wire_batch_size_is_clamped) {
  ASSERT_EQ(wire_cases::make_core(Consent(), 9999, 10).batch_size(), feralin::wire::kMaxBatchSize);
  ASSERT_EQ(wire_cases::make_core(Consent(), 0, 10).batch_size(), 1);
  ASSERT_EQ(wire_cases::make_core(Consent(), 10, 0).queue_limit(), 1);
}

TEST_CASE(wire_retry_keeps_pinned_batch_and_backoff) {
  EventCore core = wire_cases::make_core(wire_cases::analytics_only());
  const std::string first = core.track("first_event", Value(), TrackOptions(), wire_cases::kNow, wire_cases::zero_fill).event_id;
  feralin::wire::Batch batch = core.peek();
  const std::string key = EventCore::batch_key(batch);

  feralin::wire::DeliveryResult result = core.on_network_error(batch, "kopuk", 1000);
  ASSERT_TRUE(result.error.code == feralin::wire::ErrorCode::temporary);
  ASSERT_EQ(result.retained, 1);
  ASSERT_EQ(core.backoff_ms(), std::int64_t{1000});
  // Yarım jitter: bekleme nominal sürenin yarısından az, tamamından çok olamaz.
  ASSERT_TRUE(core.in_backoff(1499));
  ASSERT_TRUE(!core.in_backoff(2000));

  // Araya giren olay anahtarı değiştirmez.
  const std::string second = core.track("second_event", Value(), TrackOptions(), wire_cases::kNow, wire_cases::zero_fill).event_id;
  batch = core.peek();
  ASSERT_EQ(batch.size(), std::size_t{1});
  ASSERT_EQ(EventCore::batch_key(batch), key);

  result = core.on_response(batch, 503, "{}", " 5 ", 2000);
  ASSERT_EQ(result.status, 503);
  ASSERT_EQ(core.backoff_ms(), std::int64_t{5000});
  // Retry-After alt sınırdır: jitter onun altına düşüremez.
  ASSERT_TRUE(core.in_backoff(6999));
  ASSERT_TRUE(!core.in_backoff(7000));
  result = core.on_response(batch, 429, "{}", "1", 3000);
  ASSERT_EQ(core.backoff_ms(), std::int64_t{10000});
  for (int i = 0; i < 6; ++i) result = core.on_response(batch, 500, "{}", "tarih değil", 4000);
  ASSERT_EQ(core.backoff_ms(), feralin::wire::kMaxBackoffMs);
  ASSERT_EQ(EventCore::batch_key(core.peek()), key);

  result = core.on_response(core.peek(), 202, "{\"batch_id\":\"01B\",\"accepted\":1,\"rejected\":0}", "", 5000);
  ASSERT_TRUE(result.ok());
  ASSERT_EQ(result.batch_id, std::string("01B"));
  ASSERT_EQ(core.backoff_ms(), std::int64_t{0});
  ASSERT_EQ(core.queued(), std::size_t{1});
  ASSERT_EQ(core.peek()[0].id, second);
  ASSERT_TRUE(first != second);
}

TEST_CASE(wire_ack_without_valid_json_counts_all_accepted) {
  EventCore core = wire_cases::make_core(wire_cases::analytics_only());
  core.track("e", Value(), TrackOptions(), wire_cases::kNow, wire_cases::zero_fill);
  const feralin::wire::DeliveryResult result = core.on_response(core.peek(), 202, "<html>", "", 0);
  ASSERT_TRUE(result.ok());
  ASSERT_EQ(result.accepted, 1);
  ASSERT_EQ(core.queued(), std::size_t{0});
}

TEST_CASE(wire_invalid_key_drops_whole_queue) {
  for (const int status : {401, 403}) {
    EventCore core = wire_cases::make_core(wire_cases::analytics_only(), 2, 100);
    for (int i = 0; i < 5; ++i) core.track("e", Value(), TrackOptions(), wire_cases::kNow, wire_cases::zero_fill);
    const feralin::wire::DeliveryResult result = core.on_response(core.peek(), status, "{\"title\":\"Anahtar geçersiz\",\"detail\":\"x\"}", "", 0);
    ASSERT_TRUE(result.error.code == feralin::wire::ErrorCode::rejected);
    ASSERT_EQ(result.rejected, 5);
    ASSERT_EQ(result.sent, 2);
    ASSERT_EQ(core.queued(), std::size_t{0});
    ASSERT_TRUE(result.error.message.find("Anahtar geçersiz") != std::string::npos);
  }
}

TEST_CASE(wire_other_4xx_drops_only_batch) {
  EventCore core = wire_cases::make_core(wire_cases::analytics_only(), 2, 100);
  for (int i = 0; i < 5; ++i) core.track("e", Value(), TrackOptions(), wire_cases::kNow, wire_cases::zero_fill);
  const feralin::wire::DeliveryResult result = core.on_response(core.peek(), 400, "bozuk gövde", "", 0);
  ASSERT_TRUE(result.error.code == feralin::wire::ErrorCode::rejected);
  ASSERT_EQ(result.rejected, 2);
  ASSERT_EQ(core.queued(), std::size_t{3});
  ASSERT_TRUE(result.error.message.find("problem+json yok") != std::string::npos);
}

TEST_CASE(wire_consent_withdrawal_clears_pinned) {
  EventCore core = wire_cases::make_core(wire_cases::analytics_only());
  core.track("e", Value(), TrackOptions(), wire_cases::kNow, wire_cases::zero_fill);
  const feralin::wire::Batch batch = core.peek();
  core.on_network_error(batch, "kopuk", 0);
  core.set_consent(Consent());
  ASSERT_EQ(core.queued(), std::size_t{0});
  ASSERT_TRUE(core.peek().empty());
  // İstek sürerken izin çekildiyse dönen hata batch'i geri sabitleyemez.
  core.on_network_error(batch, "kopuk", 0);
  ASSERT_TRUE(core.peek().empty());
}

TEST_CASE(wire_problem_summary_is_bounded) {
  const std::string body = "{\"title\":\"" + std::string(300, 's') + "\"}";
  ASSERT_EQ(feralin::wire::problem_summary(body).size(), std::size_t{200});
  ASSERT_EQ(feralin::wire::problem_summary("{}"), std::string("problem+json yok"));
  ASSERT_EQ(feralin::wire::problem_summary("[1]"), std::string("problem+json yok"));
  ASSERT_EQ(feralin::wire::problem_summary("{\"title\":\" Şema ihlali \",\"detail\":\"events[0]\"}"), std::string("Şema ihlali events[0]"));
}
