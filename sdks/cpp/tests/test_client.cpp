// C++ istemcisinin birim testleri. Davranış kaynağı: sdks/python/tests/test_client.py.
#include <atomic>
#include <chrono>
#include <fstream>
#include <memory>
#include <regex>
#include <set>
#include <thread>

#include "test_support.hpp"

#define WIRE_TEST_IDENTITY (feralin::wire::SdkIdentity{feralin::kSdkName, feralin::kSdkVersion, feralin::kPlatform})
#include "wire_cases.inc"

using feralin::Client;
using feralin::Consent;
using feralin::ErrorCode;
using feralin::FlushResult;
using feralin::Options;
using feralin::Properties;
using feralin::TrackOptions;
using feralin::TrackResult;
using feralin::Value;
using test::FakeTransport;
using test::ScriptedResponse;

namespace {

Consent analytics() {
  Consent consent;
  consent.analytics = true;
  return consent;
}

struct Fixture {
  std::shared_ptr<FakeTransport> transport = std::make_shared<FakeTransport>();

  std::unique_ptr<Client> make(Options options = Options()) const {
    if (options.project_key.empty()) options.project_key = test::kTestKey;
    if (options.collect_url.empty()) options.collect_url = "https://collect.example.test";
    options.transport = transport;
    feralin::Error error;
    auto client = Client::create(std::move(options), &error);
    if (!client) throw std::runtime_error("istemci açılamadı: " + error.message);
    return client;
  }

  std::unique_ptr<Client> make_quiet(Consent consent = analytics()) const {
    Options options;
    options.consent = consent;
    options.flush_interval_ms = 0;  // arka plan kapalı; testler flush/close ile denetler
    return make(std::move(options));
  }
};

ScriptedResponse scripted(int status, const std::string& body = "{}", const std::string& retry_after = "") {
  ScriptedResponse response;
  response.status = status;
  response.body = body;
  response.retry_after = retry_after;
  return response;
}

ScriptedResponse network_down() {
  ScriptedResponse response;
  response.network_error = true;
  return response;
}

void assert_wire_event(const Value& wire) {
  for (const char* key : {"event_id", "event_name", "occurred_at", "platform", "schema_version", "consent"}) {
    ASSERT_TRUE(wire.find(key) != nullptr);
  }
  for (const char* forbidden : {"tenant_id", "project_id", "verified", "source_ip", "ip"}) {
    ASSERT_TRUE(wire.find(forbidden) == nullptr);
  }
  ASSERT_TRUE(feralin::wire::is_ulid(wire.find("event_id")->as_string()));
  ASSERT_EQ(wire.find("platform")->as_string(), std::string("cpp"));
  ASSERT_EQ(wire.find("schema_version")->as_int(), std::int64_t{1});
  ASSERT_EQ(wire.find("sdk")->find("name")->as_string(), std::string("feralin-cpp"));
  ASSERT_EQ(wire.find("sdk")->find("version")->as_string(), std::string(FERALIN_SDK_VERSION));
  const std::regex occurred_at(R"(^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$)");
  ASSERT_TRUE(std::regex_match(wire.find("occurred_at")->as_string(), occurred_at));
  ASSERT_TRUE(wire.find("consent")->find("analytics")->as_bool());

  // Gerçek şema dosyası: bilinmeyen alan gönderilmez, zorunlu alan eksik kalmaz.
  std::ifstream file(FERALIN_SCHEMA_PATH, std::ios::binary);
  ASSERT_TRUE(file.good());
  std::stringstream content;
  content << file.rdbuf();
  const Value schema = test::parsed(content.str());
  const Value* allowed = schema.find("properties");
  for (std::size_t i = 0; i < wire.size(); ++i) {
    ASSERT_TRUE(allowed->find(wire.key_at(i)) != nullptr);
  }
  const Value* required = schema.find("required");
  for (std::size_t i = 0; i < required->size(); ++i) {
    ASSERT_TRUE(wire.find(required->at(i).as_string()) != nullptr);
  }
}

}  // namespace

TEST_CASE(config_rejects_secret_and_non_pk_keys) {
  Options options;
  options.collect_url = "https://collect.example.test";
  options.transport = std::make_shared<FakeTransport>();
  feralin::Error error;
  options.project_key = "sk_live_abcdefgh";
  ASSERT_TRUE(Client::create(options, &error) == nullptr);
  ASSERT_TRUE(error.code == ErrorCode::configuration);
  ASSERT_TRUE(error.message.find("gizli anahtar") != std::string::npos);
  options.project_key = "dev_key_change_me_0001";
  ASSERT_TRUE(Client::create(options, &error) == nullptr);
  options.project_key = "";
  ASSERT_TRUE(Client::create(options, &error) == nullptr);
}

TEST_CASE(config_rejects_bad_url_and_timeout) {
  Options options;
  options.project_key = test::kTestKey;
  options.transport = std::make_shared<FakeTransport>();
  options.collect_url = "collect.example.test";
  ASSERT_TRUE(Client::create(options) == nullptr);
  options.collect_url = "ftp://collect.example.test";
  ASSERT_TRUE(Client::create(options) == nullptr);
  options.collect_url = "https://collect.example.test";
  options.timeout_ms = 0;
  ASSERT_TRUE(Client::create(options) == nullptr);
}

TEST_CASE(status_does_not_leak_key) {
  Fixture fixture;
  auto client = fixture.make_quiet();
  const feralin::ClientStatus status = client->status();
  ASSERT_EQ(status.endpoint, std::string("https://collect.example.test/v1/batch"));
  ASSERT_EQ(status.sdk, std::string("feralin-cpp"));
  ASSERT_TRUE(status.endpoint.find("pk_") == std::string::npos);
}

TEST_CASE(track_flush_accepted) {
  Fixture fixture;
  auto client = fixture.make_quiet();
  ASSERT_TRUE(!client->identify("user_42").failed());
  TrackOptions options;
  options.anonymous_id = "anon_1";
  options.session_id = "ses_1";
  feralin::Context context;
  context.locale = "tr-TR";
  context.timezone = "Europe/Istanbul";
  context.app_version = "1.2.3";
  options.context = context;
  const TrackResult event = client->track("order_completed", {{"order_id", "ord_1"}, {"amount", 12.5}, {"items", 2}}, options);
  ASSERT_TRUE(event.ok() && event.produced);
  ASSERT_EQ(client->queue_length(), std::size_t{1});

  const FlushResult result = client->flush();
  ASSERT_TRUE(result.ok());
  ASSERT_EQ(result.status, 202);
  ASSERT_EQ(result.sent, 1);
  ASSERT_EQ(result.accepted, 1);
  ASSERT_EQ(result.rejected, 0);
  ASSERT_EQ(result.batch_id, std::string("01TESTBATCH0000000000000000"));
  ASSERT_EQ(client->queue_length(), std::size_t{0});
  ASSERT_EQ(fixture.transport->count(), std::size_t{1});

  const feralin::HttpRequest request = fixture.transport->request(0);
  ASSERT_EQ(request.url, std::string("https://collect.example.test/v1/batch"));
  ASSERT_EQ(test::header(request, "X-Feralin-Project-Key"), std::string(test::kTestKey));
  ASSERT_EQ(test::header(request, "Idempotency-Key"), feralin::wire::idempotency_key_for({event.event_id}));
  ASSERT_EQ(test::header(request, "Content-Type"), std::string("application/json"));
  ASSERT_EQ(test::header(request, "User-Agent"), std::string("feralin-cpp/") + FERALIN_SDK_VERSION);
  const Value body = test::body_of(request);
  ASSERT_TRUE(body.find("sent_at") != nullptr);
  const Value* events = body.find("events");
  ASSERT_EQ(events->size(), std::size_t{1});
  const Value& wire = events->at(0);
  assert_wire_event(wire);
  ASSERT_EQ(wire.find("user_id")->as_string(), std::string("user_42"));
  ASSERT_EQ(wire.find("anonymous_id")->as_string(), std::string("anon_1"));
  ASSERT_EQ(wire.find("session_id")->as_string(), std::string("ses_1"));
  ASSERT_EQ(wire.find("event_id")->as_string(), event.event_id);
  ASSERT_EQ(wire.find("properties")->find("order_id")->as_string(), std::string("ord_1"));
  ASSERT_TRUE(wire.find("properties")->find("amount")->as_double() == 12.5);
  ASSERT_EQ(wire.find("properties")->find("items")->as_int(), std::int64_t{2});
  ASSERT_EQ(wire.find("context")->find("timezone")->as_string(), std::string("Europe/Istanbul"));
  ASSERT_EQ(wire.find("context")->find("app")->find("version")->as_string(), std::string("1.2.3"));
}

TEST_CASE(optional_fields_omitted) {
  Fixture fixture;
  auto client = fixture.make_quiet();
  const TrackResult event = client->track("signup");
  const Value parsed = test::parsed(event.event_json);
  for (const char* key : {"user_id", "anonymous_id", "session_id", "properties", "context"}) {
    ASSERT_TRUE(parsed.find(key) == nullptr);
  }
  client->flush();
  assert_wire_event(test::body_of(fixture.transport->request(0)).find("events")->at(0));
}

TEST_CASE(per_event_user_overrides_identify) {
  Fixture fixture;
  auto client = fixture.make_quiet();
  client->identify("user_default");
  TrackOptions options;
  options.user_id = "user_override";
  ASSERT_TRUE(client->track("a", {}, options).event_json.find("user_override") != std::string::npos);
  ASSERT_TRUE(client->track("b").event_json.find("user_default") != std::string::npos);
  client->identify("");
  ASSERT_TRUE(client->track("c").event_json.find("user_id") == std::string::npos);
}

TEST_CASE(temporary_failure_keeps_queue_and_idempotency_key) {
  Fixture fixture;
  fixture.transport->script({scripted(503, "{\"title\":\"Outbox yazılamadı\"}", "5"), scripted(429, "{\"title\":\"Çok fazla istek\"}", "1")});
  auto client = fixture.make_quiet();
  const TrackResult event = client->track("signup");

  FlushResult result = client->flush();
  ASSERT_TRUE(result.error.code == ErrorCode::temporary);
  ASSERT_EQ(result.status, 503);
  ASSERT_EQ(result.retained, 1);
  ASSERT_EQ(client->status().backoff_ms, std::int64_t{5000});

  result = client->flush();
  ASSERT_TRUE(result.error.code == ErrorCode::temporary);
  ASSERT_EQ(result.status, 429);
  ASSERT_EQ(client->status().backoff_ms, std::int64_t{10000});

  result = client->flush();
  ASSERT_TRUE(result.ok());
  ASSERT_EQ(result.status, 202);
  ASSERT_EQ(client->queue_length(), std::size_t{0});
  ASSERT_EQ(client->status().backoff_ms, std::int64_t{0});

  ASSERT_EQ(fixture.transport->count(), std::size_t{3});
  const std::string expected = feralin::wire::idempotency_key_for({event.event_id});
  for (std::size_t i = 0; i < 3; ++i) ASSERT_EQ(test::header(fixture.transport->request(i), "Idempotency-Key"), expected);
}

TEST_CASE(pinned_batch_keeps_content_across_retries) {
  Fixture fixture;
  fixture.transport->script({scripted(503)});
  auto client = fixture.make_quiet();
  const TrackResult first = client->track("first_event");
  ASSERT_TRUE(client->flush().error.code == ErrorCode::temporary);
  const TrackResult second = client->track("second_event");
  ASSERT_TRUE(client->flush().ok());
  ASSERT_EQ(fixture.transport->count(), std::size_t{3});
  const std::string key = feralin::wire::idempotency_key_for({first.event_id});
  ASSERT_EQ(test::header(fixture.transport->request(0), "Idempotency-Key"), key);
  ASSERT_EQ(test::header(fixture.transport->request(1), "Idempotency-Key"), key);
  ASSERT_EQ(test::header(fixture.transport->request(2), "Idempotency-Key"), feralin::wire::idempotency_key_for({second.event_id}));
  // Yeniden denemede olaylar aynıdır; yalnız sent_at değişebilir.
  ASSERT_EQ(test::body_of(fixture.transport->request(1)).find("events")->size(), std::size_t{1});
}

TEST_CASE(network_error_keeps_queue) {
  Fixture fixture;
  fixture.transport->script({network_down()});
  auto client = fixture.make_quiet();
  client->track("ping");
  const FlushResult result = client->flush();
  ASSERT_TRUE(result.error.code == ErrorCode::temporary);
  ASSERT_EQ(result.status, 0);
  ASSERT_EQ(client->queue_length(), std::size_t{1});
  ASSERT_EQ(client->status().backoff_ms, std::int64_t{1000});
}

TEST_CASE(transport_exception_is_network_error) {
  class Throwing final : public feralin::Transport {
   public:
    feralin::HttpResponse post(const feralin::HttpRequest&) override { throw std::runtime_error("patladı"); }
  };
  Options options;
  options.project_key = test::kTestKey;
  options.collect_url = "https://collect.example.test";
  options.consent = analytics();
  options.flush_interval_ms = 0;
  options.transport = std::make_shared<Throwing>();
  auto client = Client::create(options);
  ASSERT_TRUE(client != nullptr);
  client->track("ping");
  const FlushResult result = client->flush();
  ASSERT_TRUE(result.error.code == ErrorCode::temporary);
  ASSERT_EQ(client->queue_length(), std::size_t{1});
  client->set_consent(Consent());
}

TEST_CASE(permanent_rejection_drops_events) {
  Fixture fixture;
  fixture.transport->script({scripted(400, "{\"title\":\"Şema ihlali\",\"detail\":\"events[0]\"}")});
  auto client = fixture.make_quiet();
  client->track("client_valid_but_server_rejects");
  const FlushResult result = client->flush();
  ASSERT_TRUE(result.error.code == ErrorCode::rejected);
  ASSERT_TRUE(result.error.message.find("Şema ihlali") != std::string::npos);
  ASSERT_EQ(result.status, 400);
  ASSERT_EQ(result.rejected, 1);
  ASSERT_EQ(client->queue_length(), std::size_t{0});
  ASSERT_TRUE(client->flush().ok());
  ASSERT_EQ(fixture.transport->count(), std::size_t{1});  // atılan olay yeniden gönderilmez
}

TEST_CASE(unauthorized_drops_whole_queue_without_crash) {
  Options options;
  options.consent = analytics();
  options.flush_interval_ms = 0;
  options.batch_size = 2;
  Fixture fixture;
  fixture.transport->script({scripted(401, "{\"title\":\"Yetkisiz\"}")});
  auto client = fixture.make(options);
  for (int i = 0; i < 5; ++i) client->track("e");
  const FlushResult result = client->flush();
  ASSERT_TRUE(result.error.code == ErrorCode::rejected);
  ASSERT_EQ(result.status, 401);
  ASSERT_EQ(result.rejected, 5);
  ASSERT_EQ(client->queue_length(), std::size_t{0});
  ASSERT_EQ(fixture.transport->count(), std::size_t{1});
  ASSERT_TRUE(result.error.message.find(test::kTestKey) == std::string::npos);
}

TEST_CASE(consent_gate) {
  Fixture fixture;
  auto client = fixture.make_quiet(Consent());
  ASSERT_TRUE(!client->track("page_view").produced);
  ASSERT_EQ(client->queue_length(), std::size_t{0});

  client->set_consent(analytics());
  const TrackResult event = client->track("page_view");
  ASSERT_TRUE(event.produced);
  ASSERT_TRUE(event.event_json.find("\"consent\":{\"analytics\":true,\"advertising\":false,\"personalization\":false,\"session_replay\":false}") != std::string::npos);
  ASSERT_EQ(client->queue_length(), std::size_t{1});

  client->set_consent(Consent());
  ASSERT_EQ(client->queue_length(), std::size_t{0});
  ASSERT_TRUE(client->flush().ok());
  ASSERT_EQ(fixture.transport->count(), std::size_t{0});  // izin yokken sunucuya istek gitmez
}

TEST_CASE(fr_click_requires_advertising_consent) {
  Fixture fixture;
  auto client = fixture.make_quiet();
  TrackResult event = client->track("order_completed", {{"fr_click", "clk"}, {"order_id", "o1"}});
  ASSERT_TRUE(event.event_json.find("fr_click") == std::string::npos);
  ASSERT_TRUE(event.event_json.find("\"order_id\":\"o1\"") != std::string::npos);
  Consent both = analytics();
  both.advertising = true;
  client->set_consent(both);
  event = client->track("order_completed", {{"fr_click", "clk"}});
  ASSERT_TRUE(event.event_json.find("\"fr_click\":\"clk\"") != std::string::npos);
}

TEST_CASE(batch_splitting) {
  Options options;
  options.consent = analytics();
  options.flush_interval_ms = 0;
  options.batch_size = 2;
  options.queue_limit = 100;
  Fixture fixture;
  auto client = fixture.make(options);
  for (int i = 0; i < 5; ++i) client->track("e");
  const FlushResult result = client->flush();
  ASSERT_TRUE(result.ok());
  ASSERT_EQ(result.sent, 5);
  ASSERT_EQ(result.accepted, 5);
  ASSERT_EQ(client->queue_length(), std::size_t{0});
  ASSERT_EQ(fixture.transport->count(), std::size_t{3});
  const feralin::HttpRequest first = fixture.transport->request(0);
  const Value body = test::body_of(first);
  ASSERT_EQ(body.find("events")->size(), std::size_t{2});
  std::vector<std::string> ids;
  for (std::size_t i = 0; i < 2; ++i) ids.push_back(body.find("events")->at(i).find("event_id")->as_string());
  ASSERT_EQ(test::header(first, "Idempotency-Key"), feralin::wire::idempotency_key_for(ids));
  ASSERT_EQ(test::body_of(fixture.transport->request(2)).find("events")->size(), std::size_t{1});
}

TEST_CASE(background_flush) {
  Options options;
  options.consent = analytics();
  options.flush_interval_ms = 20;
  Fixture fixture;
  auto client = fixture.make(options);
  client->track("bg");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (client->queue_length() != 0 && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  ASSERT_EQ(client->queue_length(), std::size_t{0});
  ASSERT_EQ(fixture.transport->count(), std::size_t{1});
}

TEST_CASE(full_queue_wakes_background_sender) {
  Options options;
  options.consent = analytics();
  options.flush_interval_ms = 3600000;  // aralık pratikte hiç dolmasın
  options.batch_size = 2;
  Fixture fixture;
  auto client = fixture.make(options);
  client->track("a");
  client->track("b");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (fixture.transport->count() == 0 && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(std::chrono::milliseconds(5));
  ASSERT_EQ(fixture.transport->count(), std::size_t{1});
}

TEST_CASE(background_flush_respects_backoff) {
  Options options;
  options.consent = analytics();
  options.flush_interval_ms = 10;
  Fixture fixture;
  fixture.transport->script({scripted(503, "{\"title\":\"down\"}")});
  auto client = fixture.make(options);
  client->track("bg");
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
  while (fixture.transport->count() == 0 && std::chrono::steady_clock::now() < deadline) std::this_thread::sleep_for(std::chrono::milliseconds(2));
  std::this_thread::sleep_for(std::chrono::milliseconds(150));
  ASSERT_EQ(fixture.transport->count(), std::size_t{1});  // geri çekilme sırasında yeniden deneme yok
  ASSERT_EQ(client->queue_length(), std::size_t{1});
  client->set_consent(Consent());
}

TEST_CASE(close_flushes_and_blocks_track) {
  Options options;
  options.consent = analytics();
  options.flush_interval_ms = 3600000;
  Fixture fixture;
  auto client = fixture.make(options);
  for (int i = 0; i < 3; ++i) client->track("e");
  const FlushResult result = client->close();
  ASSERT_TRUE(result.ok());
  ASSERT_EQ(fixture.transport->count(), std::size_t{1});
  ASSERT_EQ(test::body_of(fixture.transport->request(0)).find("events")->size(), std::size_t{3});
  ASSERT_EQ(client->queue_length(), std::size_t{0});
  ASSERT_TRUE(client->status().closed);
  ASSERT_TRUE(client->track("late").error.code == ErrorCode::client_closed);
  ASSERT_TRUE(client->flush().error.code == ErrorCode::client_closed);
  ASSERT_TRUE(client->close().ok());  // ikinci close hatasız
}

TEST_CASE(close_reports_undelivered) {
  Fixture fixture;
  fixture.transport->script({scripted(503, "{\"title\":\"down\"}")});
  auto client = fixture.make_quiet();
  client->track("e");
  const FlushResult result = client->close(1000);
  ASSERT_TRUE(result.error.code == ErrorCode::temporary);
  ASSERT_EQ(result.retained, 1);
}

TEST_CASE(destructor_flushes) {
  Fixture fixture;
  {
    auto client = fixture.make_quiet();
    client->track("ctx");
  }
  ASSERT_EQ(fixture.transport->count(), std::size_t{1});
}

TEST_CASE(concurrent_track) {
  Options options;
  options.consent = analytics();
  options.flush_interval_ms = 0;
  options.queue_limit = 5000;
  options.batch_size = feralin::wire::kMaxBatchSize;
  Fixture fixture;
  auto client = fixture.make(options);
  std::vector<std::thread> threads;
  for (int t = 0; t < 8; ++t) {
    threads.emplace_back([&client] {
      for (int i = 0; i < 100; ++i) client->track("c");
    });
  }
  for (std::thread& thread : threads) thread.join();
  ASSERT_EQ(client->queue_length(), std::size_t{800});
  const FlushResult result = client->flush();
  ASSERT_TRUE(result.ok());
  ASSERT_EQ(result.accepted, 800);
  ASSERT_EQ(client->queue_length(), std::size_t{0});
  ASSERT_EQ(fixture.transport->count(), std::size_t{2});
  std::set<std::string> seen;
  for (std::size_t i = 0; i < 2; ++i) {
    const Value body = test::body_of(fixture.transport->request(i));
    const Value* events = body.find("events");
    for (std::size_t k = 0; k < events->size(); ++k) ASSERT_TRUE(seen.insert(events->at(k).find("event_id")->as_string()).second);
  }
  ASSERT_EQ(seen.size(), std::size_t{800});
}

TEST_CASE(occurred_at_uses_injected_clock) {
  Options options;
  options.consent = analytics();
  options.flush_interval_ms = 0;
  options.now_ms = [] { return std::int64_t{1793690400123}; };
  Fixture fixture;
  auto client = fixture.make(options);
  ASSERT_EQ(test::parsed(client->track("clock").event_json).find("occurred_at")->as_string(), std::string("2026-11-03T07:20:00.123Z"));
  TrackOptions explicit_time;
  explicit_time.occurred_at_ms = 1767323045000;
  ASSERT_EQ(test::parsed(client->track("clock", {}, explicit_time).event_json).find("occurred_at")->as_string(), std::string("2026-01-02T03:04:05.000Z"));
}

TEST_CASE(logger_never_sees_key_or_body) {
  Options options;
  options.consent = analytics();
  options.flush_interval_ms = 0;
  options.queue_limit = 1;
  std::vector<std::string> messages;
  options.logger = [&messages](feralin::LogLevel, const std::string& message) { messages.push_back(message); };
  Fixture fixture;
  fixture.transport->script({scripted(403, "{\"title\":\"Yasak\"}")});
  auto client = fixture.make(options);
  client->track("first", {{"secret_prop", "GIZLI"}});
  client->track("second", {{"secret_prop", "GIZLI"}});  // kuyruk sınırı uyarısı
  client->flush();  // red uyarısı
  ASSERT_TRUE(messages.size() >= 2);
  for (const std::string& message : messages) {
    ASSERT_TRUE(message.find(test::kTestKey) == std::string::npos);
    ASSERT_TRUE(message.find("GIZLI") == std::string::npos);
  }
}

int main() { return test::run_all(); }
