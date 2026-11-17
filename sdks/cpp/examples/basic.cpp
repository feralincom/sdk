// En kısa kullanım: FERALIN_PROJECT_KEY ve FERALIN_COLLECT_URL ortam değişkenleriyle çalışır.
#include <cstdio>
#include <cstdlib>

#include <feralin/feralin.hpp>

int main() {
  const char* key = std::getenv("FERALIN_PROJECT_KEY");
  const char* url = std::getenv("FERALIN_COLLECT_URL");
  if (key == nullptr || url == nullptr) {
    std::fputs("FERALIN_PROJECT_KEY ve FERALIN_COLLECT_URL gerekli\n", stderr);
    return 2;
  }
  feralin::Options options;
  options.project_key = key;
  options.collect_url = url;
  options.consent.analytics = true;  // izni uygulama kullanıcıdan alır; varsayılan kapalıdır

  feralin::Error error;
  auto client = feralin::Client::create(options, &error);
  if (!client) {
    std::fprintf(stderr, "yapılandırma hatası: %s\n", error.message.c_str());
    return 2;
  }
  client->track("order_completed", {{"order_id", "ord_1"}, {"amount", 249.9}});
  const feralin::FlushResult result = client->close();
  std::printf("durum=%d kabul=%d red=%d batch=%s hata=%s\n", result.status, result.accepted, result.rejected, result.batch_id.c_str(), result.error.message.c_str());
  return result.ok() ? 0 : 1;
}
