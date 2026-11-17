// Gerçek services/collect tüketicisi: scripts/sdk-e2e/run.mjs cpp tarafından temiz kurulumla çalıştırılır.
// Senaryolar sdks/python/examples/e2e_consumer.py ile aynıdır; denetim satırları PostgreSQL üzerinde doğrulanır.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include <feralin/feralin.hpp>

namespace {

std::string required_env(const char* name) {
  const char* value = std::getenv(name);
  if (value == nullptr || *value == '\0') {
    std::fprintf(stderr, "KALDI: %s ortam değişkeni yok\n", name);
    std::exit(1);
  }
  return value;
}

const std::string kCollectUrl = required_env("FERALIN_E2E_COLLECT_URL");
const std::string kProjectKey = required_env("FERALIN_E2E_PROJECT_KEY");
const std::string kChecks = required_env("FERALIN_E2E_CHECKS");

void must(bool condition, const char* message) {
  if (!condition) {
    std::fprintf(stderr, "KALDI: %s\n", message);
    std::exit(1);
  }
}

void expect_line(const std::string& line) {
  std::ofstream file(kChecks, std::ios::app | std::ios::binary);
  file << line << "\n";
}

std::unique_ptr<feralin::Client> make(const feralin::Consent& consent, const std::string& key = kProjectKey, std::shared_ptr<feralin::Transport> transport = nullptr) {
  feralin::Options options;
  options.project_key = key;
  options.collect_url = kCollectUrl;
  options.consent = consent;
  options.flush_interval_ms = 0;
  options.transport = std::move(transport);
  feralin::Error error;
  auto client = feralin::Client::create(options, &error);
  must(client != nullptr, "istemci açılamadı");
  return client;
}

feralin::Consent consent_of(bool analytics, bool advertising) {
  feralin::Consent consent;
  consent.analytics = analytics;
  consent.advertising = advertising;
  return consent;
}

// Sunucu yazdı ama yanıt kayboldu: ilk istek gerçekten gider, sonucu çağırana ulaşmaz.
class LossyTransport final : public feralin::Transport {
 public:
  feralin::HttpResponse post(const feralin::HttpRequest& request) override {
    for (const auto& header : request.headers) {
      if (header.first == "Idempotency-Key") keys.push_back(header.second);
    }
    feralin::HttpResponse response = inner_->post(request);
    if (keys.size() == 1) {
      feralin::HttpResponse lost;
      lost.error = "yanıt yolda kayboldu";
      return lost;
    }
    return response;
  }

  std::vector<std::string> keys;

 private:
  std::shared_ptr<feralin::Transport> inner_ = feralin::default_transport();
};

}  // namespace

int main() {
  std::printf("  kurulu paket: feralin-cpp %s\n", feralin_version());

  // 202 + outbox satırı + fr_click reklam izniyle
  {
    auto client = make(consent_of(true, true));
    feralin::TrackOptions options;
    options.user_id = "user_cpp_1";
    const feralin::TrackResult event = client->track("order_completed", {{"order_id", "ord_cpp_1"}, {"fr_click", "clk_cpp_1"}}, options);
    const feralin::FlushResult result = client->flush();
    must(event.produced && result.status == 202 && result.accepted == 1, "202 bekleniyordu");
    must(!result.batch_id.empty(), "batch_id bekleniyordu");
    expect_line("frclick " + result.batch_id);
    expect_line("once " + event.event_id);
    expect_line("platform cpp:" + event.event_id);
    std::printf("  OK 202-outbox-frclick: status=%d batch_id=%s\n", result.status, result.batch_id.c_str());
  }

  // Reklam izni yok: fr_click çıkarılır
  {
    auto client = make(consent_of(true, false));
    const feralin::TrackResult event = client->track("order_completed", {{"order_id", "ord_cpp_2"}, {"fr_click", "clk_cpp_2"}});
    must(event.produced && event.event_json.find("fr_click") == std::string::npos, "fr_click çıkarılmalıydı");
    const feralin::FlushResult result = client->flush();
    must(result.status == 202, "202 bekleniyordu");
    expect_line("nofrclick " + result.batch_id);
    std::printf("  OK frclick-izinsiz-cikarildi: status=%d\n", result.status);
  }

  // İzinsiz: SDK olay üretmez
  {
    auto client = make(consent_of(false, false));
    must(!client->track("order_completed").produced && client->flush().sent == 0, "izinsiz olay üretilmemeliydi");
    std::printf("  OK izinsiz-sdk-uretmez: sent=0\n");
  }

  // İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
  {
    const auto now = std::chrono::system_clock::now().time_since_epoch();
    const long long nanos = std::chrono::duration_cast<std::chrono::nanoseconds>(now).count();
    const long long millis = std::chrono::duration_cast<std::chrono::milliseconds>(now).count();
    std::string digits = std::to_string(nanos);
    digits.insert(0, 20 - digits.size(), '0');
    const std::string event_id = "01JCCP" + digits;
    const std::string body = "{\"events\":[{\"event_id\":\"" + event_id + "\",\"event_name\":\"denied_event\",\"occurred_at\":\"" + feralin::wire::format_time(millis) +
                             "\",\"platform\":\"cpp\",\"schema_version\":1,\"consent\":{\"analytics\":false}}]}";
    feralin::HttpRequest request;
    request.url = kCollectUrl + "/v1/batch";
    request.body = body;
    request.timeout_ms = 10000;
    request.headers = {{"Content-Type", "application/json"}, {"X-Feralin-Project-Key", kProjectKey}, {"Idempotency-Key", feralin::wire::idempotency_key_for({event_id})}};
    const feralin::HttpResponse response = feralin::default_transport()->post(request);
    feralin::Value denied;
    must(response.status == 202 && feralin::wire::parse_json(response.body, denied), "toplayıcı 202 dönmeliydi");
    const feralin::Value* accepted = denied.find("accepted");
    const feralin::Value* reasons = denied.find("rejected_reasons");
    const feralin::Value* consent_denied = reasons != nullptr ? reasons->find("consent_denied") : nullptr;
    must(accepted != nullptr && accepted->as_int() == 0 && consent_denied != nullptr && consent_denied->as_int() == 1, "toplayıcı izinsiz olayı reddetmeliydi");
    expect_line("absent " + event_id);
    std::printf("  OK izinsiz-toplayici-red: consent_denied=1\n");
  }

  // Yanlış anahtar: 401, olay atılır, uygulama düşmez
  {
    auto client = make(consent_of(true, false), "pk_test_wrong_key_000");
    const feralin::TrackResult event = client->track("order_completed", {{"order_id", "ord_cpp_wrong"}});
    const feralin::FlushResult result = client->flush();
    must(result.error.code == feralin::ErrorCode::rejected && result.status == 401 && result.rejected == 1 && client->queue_length() == 0, "401 bekleniyordu");
    expect_line("absent " + event.event_id);
    std::printf("  OK yanlis-anahtar-401: status=%d\n", result.status);
  }

  // Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
  {
    auto lossy = std::make_shared<LossyTransport>();
    auto client = make(consent_of(true, false), kProjectKey, lossy);
    const feralin::TrackResult event = client->track("order_completed", {{"order_id", "ord_cpp_retry"}});
    const feralin::FlushResult lost = client->flush();
    must(lost.error.code == feralin::ErrorCode::temporary && client->queue_length() == 1, "yanıt kaybı kuyrukta tutulmalıydı");
    const feralin::TrackResult following = client->track("order_shipped", {{"order_id", "ord_cpp_retry"}});
    const feralin::FlushResult result = client->flush();
    must(result.ok() && result.status == 202 && client->queue_length() == 0, "tekrar 202 vermeliydi");
    must(lossy->keys.size() == 3 && lossy->keys[0] == lossy->keys[1] && lossy->keys[1] != lossy->keys[2], "aynı anahtar bekleniyordu");
    expect_line("once " + event.event_id);
    expect_line("once " + following.event_id);
    std::printf("  OK idempotency-tekrar: key=%s\n", lossy->keys[0].c_str());
  }

  std::printf("cpp tüketici: tüm senaryolar geçti\n");
  return 0;
}
