// Varsayılan HTTP katmanını (WinHTTP veya libcurl) gerçek yerel TCP sunucusuna karşı sınar.
#include <atomic>
#include <cstring>
#include <memory>
#include <thread>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
using socket_handle = SOCKET;
constexpr socket_handle kInvalidSocket = INVALID_SOCKET;
inline void close_socket(socket_handle handle) { closesocket(handle); }
using socket_length = int;
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
using socket_handle = int;
constexpr socket_handle kInvalidSocket = -1;
inline void close_socket(socket_handle handle) { ::close(handle); }
using socket_length = socklen_t;
#endif

#include "test_support.hpp"

namespace {

// Tek isteklik basit HTTP sunucusu: isteği kaydeder ve verilen ham yanıtı yazar.
class TinyServer {
 public:
  explicit TinyServer(std::string raw_response) : raw_response_(std::move(raw_response)) {
#ifdef _WIN32
    WSADATA data;
    if (WSAStartup(MAKEWORD(2, 2), &data) != 0) throw std::runtime_error("WSAStartup");
#endif
    listener_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listener_ == kInvalidSocket) throw std::runtime_error("socket");
    sockaddr_in address;
    std::memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(listener_, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0) throw std::runtime_error("bind");
    socket_length length = sizeof(address);
    if (getsockname(listener_, reinterpret_cast<sockaddr*>(&address), &length) != 0) throw std::runtime_error("getsockname");
    port_ = ntohs(address.sin_port);
    if (listen(listener_, 4) != 0) throw std::runtime_error("listen");
    thread_ = std::thread([this] { serve(); });
  }

  ~TinyServer() {
    close_socket(listener_);
    if (thread_.joinable()) thread_.join();
  }

  std::string url() const { return "http://127.0.0.1:" + std::to_string(port_) + "/v1/batch"; }

  // serve() bittikten sonra çağrılır.
  std::string finish() {
    if (thread_.joinable()) thread_.join();
    return received_;
  }

 private:
  void serve() {
    const socket_handle client = accept(listener_, nullptr, nullptr);
    if (client == kInvalidSocket) return;
    char buffer[4096];
    std::size_t expected = std::string::npos;
    for (;;) {
      const auto count = recv(client, buffer, sizeof(buffer), 0);
      if (count <= 0) break;
      received_.append(buffer, static_cast<std::size_t>(count));
      const std::size_t end = received_.find("\r\n\r\n");
      if (end != std::string::npos && expected == std::string::npos) {
        std::string lowered = received_.substr(0, end);
        for (char& c : lowered) {
          if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
        }
        const std::size_t at = lowered.find("content-length:");
        const std::size_t body_length = at == std::string::npos ? 0 : static_cast<std::size_t>(std::stoul(lowered.substr(at + 15)));
        expected = end + 4 + body_length;
      }
      if (expected != std::string::npos && received_.size() >= expected) break;
    }
    send(client, raw_response_.data(), static_cast<int>(raw_response_.size()), 0);
    close_socket(client);
  }

  std::string raw_response_;
  std::string received_;
  socket_handle listener_ = kInvalidSocket;
  unsigned short port_ = 0;
  std::thread thread_;
};

std::string http_reply(const std::string& status_line, const std::string& body, const std::string& extra_headers = "") {
  return "HTTP/1.1 " + status_line + "\r\n" + extra_headers + "Content-Length: " + std::to_string(body.size()) + "\r\nConnection: close\r\n\r\n" + body;
}

feralin::HttpRequest make_request(const std::string& url, const std::string& body) {
  feralin::HttpRequest request;
  request.url = url;
  request.body = body;
  request.timeout_ms = 5000;
  request.headers = feralin::wire::request_headers("pk_test_transport_01", "abc-1", feralin::wire::SdkIdentity{feralin::kSdkName, feralin::kSdkVersion, feralin::kPlatform});
  return request;
}

}  // namespace

TEST_CASE(transport_sends_headers_body_and_reads_202) {
  TinyServer server(http_reply("202 Accepted", "{\"batch_id\":\"01BAT\"}"));
  const std::string body = "{\"sent_at\":\"x\",\"events\":[\"ş\"]}";
  const feralin::HttpResponse response = feralin::default_transport()->post(make_request(server.url(), body));
  const std::string received = server.finish();
  ASSERT_EQ(response.status, 202);
  ASSERT_TRUE(response.error.empty());
  ASSERT_TRUE(received.rfind("POST /v1/batch HTTP/1.1\r\n", 0) == 0);
  ASSERT_TRUE(received.find("X-Feralin-Project-Key: pk_test_transport_01\r\n") != std::string::npos);
  ASSERT_TRUE(received.find("Idempotency-Key: abc-1\r\n") != std::string::npos);
  ASSERT_TRUE(received.find("Content-Type: application/json\r\n") != std::string::npos);
  ASSERT_TRUE(received.find(std::string("User-Agent: feralin-cpp/") + FERALIN_SDK_VERSION) != std::string::npos);
  ASSERT_TRUE(received.size() >= body.size() && received.compare(received.size() - body.size(), body.size(), body) == 0);
}

TEST_CASE(transport_reports_http_error_and_retry_after) {
  TinyServer server(http_reply("503 Service Unavailable", "{}", "Retry-After: 7\r\n"));
  const feralin::HttpResponse response = feralin::default_transport()->post(make_request(server.url(), "{}"));
  server.finish();
  ASSERT_EQ(response.status, 503);
  ASSERT_EQ(feralin::wire::trim(response.retry_after), std::string("7"));
  ASSERT_EQ(response.body, std::string("{}"));
}

TEST_CASE(transport_does_not_follow_redirect) {
  TinyServer server(http_reply("307 Temporary Redirect", "", "Location: http://127.0.0.1:9/elsewhere\r\n"));
  const feralin::HttpResponse response = feralin::default_transport()->post(make_request(server.url(), "{}"));
  server.finish();
  ASSERT_EQ(response.status, 307);
}

TEST_CASE(transport_limits_response_body) {
  const std::size_t size = feralin::wire::kMaxResponseBody + 1000;
  TinyServer server(http_reply("400 Bad Request", std::string(size, 'x')));
  const feralin::HttpResponse response = feralin::default_transport()->post(make_request(server.url(), "{}"));
  server.finish();
  ASSERT_EQ(response.status, 400);
  ASSERT_EQ(response.body.size(), feralin::wire::kMaxResponseBody);
}

TEST_CASE(transport_connection_refused_is_network_error) {
  std::string url;
  {
    // Boş port bul, sunucuyu kapat: bağlantı reddedilir.
    TinyServer server("");
    url = server.url();
    feralin::HttpRequest wake = make_request(url, "");
    wake.timeout_ms = 2000;
    feralin::default_transport()->post(wake);
    server.finish();
  }
  feralin::HttpRequest request = make_request(url, "{}");
  request.timeout_ms = 2000;
  const feralin::HttpResponse response = feralin::default_transport()->post(request);
  ASSERT_EQ(response.status, 0);
  ASSERT_TRUE(!response.error.empty());
  ASSERT_TRUE(response.error.find("pk_test_transport_01") == std::string::npos);
}

TEST_CASE(client_uses_default_transport_end_to_end_local) {
  TinyServer server(http_reply("202 Accepted", "{\"batch_id\":\"01TINY\",\"accepted\":1,\"rejected\":0}"));
  feralin::Options options;
  options.project_key = test::kTestKey;
  options.collect_url = server.url().substr(0, server.url().size() - std::strlen("/v1/batch"));
  options.consent.analytics = true;
  options.flush_interval_ms = 0;
  options.timeout_ms = 5000;
  auto client = feralin::Client::create(options);
  ASSERT_TRUE(client != nullptr);
  ASSERT_TRUE(client->track("local_event").produced);
  const feralin::FlushResult result = client->flush();
  server.finish();
  ASSERT_EQ(result.status, 202);
  ASSERT_EQ(result.batch_id, std::string("01TINY"));
  ASSERT_EQ(client->queue_length(), std::size_t{0});
}

int main() { return test::run_all(); }
