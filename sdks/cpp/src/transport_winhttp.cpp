// Windows HTTP katmanı: WinHTTP. Yönlendirme izlenmez; proje anahtarı başka adrese taşınmaz.
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <winhttp.h>

#include <string>

#include "feralin/feralin.hpp"

namespace feralin {

namespace {

std::wstring widen(const std::string& text) {
  if (text.empty()) return std::wstring();
  const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
  std::wstring out(static_cast<std::size_t>(length), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), &out[0], length);
  return out;
}

std::string narrow(const std::wstring& text) {
  if (text.empty()) return std::string();
  const int length = WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0, nullptr, nullptr);
  std::string out(static_cast<std::size_t>(length), '\0');
  WideCharToMultiByte(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), &out[0], length, nullptr, nullptr);
  return out;
}

class Handle {
 public:
  explicit Handle(HINTERNET handle = nullptr) : handle_(handle) {}
  ~Handle() {
    if (handle_ != nullptr) WinHttpCloseHandle(handle_);
  }
  Handle(const Handle&) = delete;
  Handle& operator=(const Handle&) = delete;
  operator HINTERNET() const { return handle_; }

 private:
  HINTERNET handle_;
};

HttpResponse network_error(const char* step) {
  HttpResponse response;
  response.error = std::string("WinHTTP ") + step + " hatası " + std::to_string(GetLastError());
  return response;
}

class WinHttpTransport final : public Transport {
 public:
  HttpResponse post(const HttpRequest& request) override {
    const std::wstring url = widen(request.url);
    URL_COMPONENTS parts;
    ZeroMemory(&parts, sizeof(parts));
    parts.dwStructSize = sizeof(parts);
    parts.dwHostNameLength = static_cast<DWORD>(-1);
    parts.dwUrlPathLength = static_cast<DWORD>(-1);
    parts.dwExtraInfoLength = static_cast<DWORD>(-1);
    if (!WinHttpCrackUrl(url.c_str(), static_cast<DWORD>(url.size()), 0, &parts)) return network_error("adres çözümleme");
    const std::wstring host(parts.lpszHostName, parts.dwHostNameLength);
    std::wstring path(parts.lpszUrlPath, parts.dwUrlPathLength);
    if (parts.lpszExtraInfo != nullptr) path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);

    const std::wstring agent = widen(std::string(kSdkName) + "/" + kSdkVersion);
    // Sistem vekil ayarı (Windows 8.1+) yoksa WinHTTP varsayılanına düşülür.
    Handle session(WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0));
    Handle fallback_session(static_cast<HINTERNET>(session) == nullptr
                                ? WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0)
                                : nullptr);
    const HINTERNET active = static_cast<HINTERNET>(session) != nullptr ? static_cast<HINTERNET>(session) : static_cast<HINTERNET>(fallback_session);
    if (active == nullptr) return network_error("oturum");
    if (!WinHttpSetTimeouts(active, request.timeout_ms, request.timeout_ms, request.timeout_ms, request.timeout_ms)) return network_error("zaman aşımı ayarı");

    Handle connection(WinHttpConnect(active, host.c_str(), parts.nPort, 0));
    if (static_cast<HINTERNET>(connection) == nullptr) return network_error("bağlantı");
    const DWORD flags = parts.nScheme == INTERNET_SCHEME_HTTPS ? WINHTTP_FLAG_SECURE : 0;
    Handle handle(WinHttpOpenRequest(connection, L"POST", path.c_str(), nullptr, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags));
    if (static_cast<HINTERNET>(handle) == nullptr) return network_error("istek");
    DWORD redirect_policy = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    if (!WinHttpSetOption(handle, WINHTTP_OPTION_REDIRECT_POLICY, &redirect_policy, sizeof(redirect_policy))) return network_error("yönlendirme ayarı");

    std::wstring headers;
    for (const auto& header : request.headers) headers += widen(header.first + ": " + header.second + "\r\n");
    const DWORD body_length = static_cast<DWORD>(request.body.size());
    if (!WinHttpSendRequest(handle, headers.c_str(), static_cast<DWORD>(headers.size()), const_cast<char*>(request.body.data()), body_length, body_length, 0)) {
      return network_error("gönderim");
    }
    if (!WinHttpReceiveResponse(handle, nullptr)) return network_error("yanıt");

    DWORD status = 0;
    DWORD status_size = sizeof(status);
    if (!WinHttpQueryHeaders(handle, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, WINHTTP_HEADER_NAME_BY_INDEX, &status, &status_size, WINHTTP_NO_HEADER_INDEX)) {
      return network_error("durum kodu");
    }

    HttpResponse response;
    wchar_t retry_after[64];
    DWORD retry_size = sizeof(retry_after);
    if (WinHttpQueryHeaders(handle, WINHTTP_QUERY_RETRY_AFTER, WINHTTP_HEADER_NAME_BY_INDEX, retry_after, &retry_size, WINHTTP_NO_HEADER_INDEX)) {
      response.retry_after = narrow(std::wstring(retry_after, retry_size / sizeof(wchar_t)));
    }
    char buffer[8192];
    while (response.body.size() < wire::kMaxResponseBody) {
      DWORD read = 0;
      // Durum kodu alındı; gövde yarım kesilse de sonuç HTTP koduna göre verilir.
      if (!WinHttpReadData(handle, buffer, sizeof(buffer), &read) || read == 0) break;
      response.body.append(buffer, std::min<std::size_t>(read, wire::kMaxResponseBody - response.body.size()));
    }
    response.status = static_cast<int>(status);
    return response;
  }
};

}  // namespace

std::shared_ptr<Transport> default_transport() { return std::make_shared<WinHttpTransport>(); }

}  // namespace feralin
