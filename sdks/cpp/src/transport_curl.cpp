// Windows dışı HTTP katmanı: libcurl. Yönlendirme izlenmez; proje anahtarı başka adrese taşınmaz.
#include <curl/curl.h>

#include <mutex>
#include <string>

#include "feralin/feralin.hpp"

namespace feralin {

namespace {

std::size_t write_body(char* data, std::size_t size, std::size_t count, void* user) {
  auto* body = static_cast<std::string*>(user);
  const std::size_t length = size * count;
  if (body->size() < wire::kMaxResponseBody) body->append(data, std::min(length, wire::kMaxResponseBody - body->size()));
  return length;  // Sınır aşılsa da bağlantı kesilmez; fazlası atılır, durum kodu korunur.
}

std::size_t write_header(char* data, std::size_t size, std::size_t count, void* user) {
  auto* retry_after = static_cast<std::string*>(user);
  const std::size_t length = size * count;
  const std::string line(data, length);
  static const std::string kName = "retry-after:";
  if (line.size() > kName.size()) {
    std::string lowered = line.substr(0, kName.size());
    for (char& c : lowered) {
      if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    if (lowered == kName) *retry_after = wire::trim(line.substr(kName.size()));
  }
  return length;
}

class CurlTransport final : public Transport {
 public:
  CurlTransport() {
    // curl_global_init iş parçacığı güvenli olmayabilir; süreç başına bir kez.
    static std::once_flag once;
    std::call_once(once, [] { curl_global_init(CURL_GLOBAL_DEFAULT); });
  }

  HttpResponse post(const HttpRequest& request) override {
    HttpResponse response;
    CURL* handle = curl_easy_init();
    if (handle == nullptr) {
      response.error = "curl_easy_init başarısız";
      return response;
    }
    curl_slist* headers = nullptr;
    bool headers_ok = true;
    for (const auto& header : request.headers) {
      curl_slist* next = curl_slist_append(headers, (header.first + ": " + header.second).c_str());
      if (next == nullptr) {
        headers_ok = false;
        break;
      }
      headers = next;
    }
    // libcurl'ün 1 KB üstü gövdeye eklediği "Expect: 100-continue" bekleme gecikmesi yaratmasın.
    if (headers_ok) {
      curl_slist* next = curl_slist_append(headers, "Expect:");
      if (next == nullptr) {
        headers_ok = false;
      } else {
        headers = next;
      }
    }
    if (!headers_ok) {
      curl_slist_free_all(headers);
      curl_easy_cleanup(handle);
      response.error = "başlık listesi kurulamadı";
      return response;
    }

    curl_easy_setopt(handle, CURLOPT_URL, request.url.c_str());
    curl_easy_setopt(handle, CURLOPT_POST, 1L);
    curl_easy_setopt(handle, CURLOPT_POSTFIELDS, request.body.data());
    curl_easy_setopt(handle, CURLOPT_POSTFIELDSIZE_LARGE, static_cast<curl_off_t>(request.body.size()));
    curl_easy_setopt(handle, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(handle, CURLOPT_TIMEOUT_MS, static_cast<long>(request.timeout_ms));
    curl_easy_setopt(handle, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(handle, CURLOPT_FOLLOWLOCATION, 0L);
    curl_easy_setopt(handle, CURLOPT_WRITEFUNCTION, write_body);
    curl_easy_setopt(handle, CURLOPT_WRITEDATA, &response.body);
    curl_easy_setopt(handle, CURLOPT_HEADERFUNCTION, write_header);
    curl_easy_setopt(handle, CURLOPT_HEADERDATA, &response.retry_after);

    const CURLcode code = curl_easy_perform(handle);
    if (code == CURLE_OK) {
      long status = 0;
      curl_easy_getinfo(handle, CURLINFO_RESPONSE_CODE, &status);
      response.status = static_cast<int>(status);
    } else {
      response.error = curl_easy_strerror(code);
      response.body.clear();
      response.retry_after.clear();
    }
    curl_slist_free_all(headers);
    curl_easy_cleanup(handle);
    return response;
  }
};

}  // namespace

std::shared_ptr<Transport> default_transport() { return std::make_shared<CurlTransport>(); }

}  // namespace feralin
