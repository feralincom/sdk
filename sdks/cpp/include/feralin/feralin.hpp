// Feralin C++17 istemcisi. Kararlı ikili arayüz feralin.h içindedir; bu başlık kaynak düzeyinde kullanılır.
// SDK hataları istisna fırlatmaz: sonuç Error alanlarında döner. Paylaşımlı kütüphane derlemesinde yalnız C API dışa açıktır; bu başlık statik bağlamayla kullanılır.
#ifndef FERALIN_HPP
#define FERALIN_HPP

#include <cstdint>
#include <exception>
#include <functional>
#include <memory>
#include <string>

#include "feralin/feralin.h"
#include "feralin/signals.hpp"
#include "feralin/wire.hpp"

namespace feralin {

using wire::Consent;
using wire::Context;
using wire::Error;
using wire::ErrorCode;
using wire::Headers;
using wire::Properties;
using wire::TrackOptions;
using wire::Value;
using FlushResult = wire::DeliveryResult;
using signals::ErrorReport;
using signals::Receipt;
using signals::RevenueInput;

constexpr const char* kSdkName = "feralin-cpp";
constexpr const char* kSdkVersion = FERALIN_SDK_VERSION;
constexpr const char* kPlatform = "cpp";

struct HttpRequest {
  std::string url;
  std::string body;
  Headers headers;
  int timeout_ms = wire::kDefaultTimeoutMs;
};

// status 0: ağ hatası veya zaman aşımı (error açıklar). HTTP hata kodları normal yanıttır.
struct HttpResponse {
  int status = 0;
  std::string body;
  std::string retry_after;
  std::string error;
};

// Dışarıdan verilebilen taşıma katmanı. Herhangi bir iş parçacığından çağrılabilir, request.timeout_ms sınırına uymalıdır;
// aksi halde close() bu çağrının bitmesini bekler. Gövde okuması wire::kMaxResponseBody ile sınırlanmalıdır.
class Transport {
 public:
  virtual ~Transport() = default;
  virtual HttpResponse post(const HttpRequest& request) = 0;
};

// Windows'ta WinHTTP, öteki sistemlerde libcurl. FERALIN_TRANSPORT=NONE ile derlendiyse nullptr döner.
std::shared_ptr<Transport> default_transport();

enum class LogLevel { debug = FERALIN_LOG_DEBUG, warning = FERALIN_LOG_WARNING, failure = FERALIN_LOG_ERROR };

struct Options {
  std::string project_key;
  std::string collect_url;
  Consent consent;                                   // varsayılan: bütün izinler kapalı
  int flush_interval_ms = wire::kDefaultFlushIntervalMs;  // <= 0: arka plan gönderici kapalı
  int batch_size = wire::kDefaultBatchSize;
  int queue_limit = wire::kDefaultQueueLimit;
  int timeout_ms = wire::kDefaultTimeoutMs;
  std::shared_ptr<Transport> transport;              // boş: default_transport()
  std::function<std::int64_t()> now_ms;              // boş: sistem saati (UTC epoch ms)
  std::function<void(LogLevel, const std::string&)> logger;  // anahtar ve ham olay içeriği yazılmaz
  std::string app_version;                           // fr_error app_version alanı (en çok 32 karakter); boş: gönderilmez
  double error_sample_rate = 1.0;                    // fr_error örnekleme oranı 0..1
};

struct TrackResult {
  Error error;
  bool produced = false;  // izin yoksa false: olay üretilmedi, hata da yok
  std::string event_id;
  std::string event_json;

  bool ok() const { return !error.failed(); }
};

// Anlık durum (debug/health). Anahtar döndürülmez.
struct ClientStatus {
  std::string sdk;
  std::string version;
  std::size_t queued = 0;
  std::int64_t dropped = 0;
  Consent consent;
  std::string user_id;
  bool closed = false;
  std::int64_t backoff_ms = 0;
  std::string endpoint;
};

// İstisnanın tür adı: RTTI varsa çözülmüş sınıf adının son bileşeni (std::runtime_error → runtime_error), yoksa "Error".
std::string error_type_name(const std::exception& error);

// UTP v1 toplayıcısına olay gönderen, iş parçacığı güvenli istemci.
class Client {
 public:
  // Geçersiz seçenekte nullptr döner ve error doldurulur.
  static std::unique_ptr<Client> create(Options options, Error* error = nullptr);

  ~Client();
  Client(const Client&) = delete;
  Client& operator=(const Client&) = delete;

  // analytics false ise bekleyen olaylar atılır ve yeni olay üretilmez.
  void set_consent(const Consent& consent);
  // Sonraki olaylar için varsayılan user_id; boş değer varsayılanı kaldırır.
  Error identify(const std::string& user_id);
  // Doğrular ve kuyruğa ekler; ağ çağrısı yapmaz.
  TrackResult track(const std::string& event_name, const Properties& properties = {}, const TrackOptions& options = {});
  // properties null veya JSON nesnesi olmalıdır.
  TrackResult track_value(const std::string& event_name, const Value& properties, const TrackOptions& options = {});
  // Satın alma ya da abonelik beyanı (feralin_purchase). İstemci beyanıdır: sunucu yalnız makbuz doğrulayıcısı onaylarsa
  // REAL_VERIFIED sayar; verified alanı hiçbir zaman gönderilmez. Sözleşme dışı girdide invalid_event döner.
  TrackResult track_revenue(const RevenueInput& input, const TrackOptions& options = {});
  // Kullanıcıyı bir gruba bağlar (fr_group). Grup kimliği geçersizse olay üretilmez, hata da dönmez (produced=false).
  TrackResult group(const std::string& group_id, const Properties& traits = {}, const TrackOptions& options = {});
  TrackResult group_value(const std::string& group_id, const Value& traits, const TrackOptions& options = {});
  // Kullanıcı özellikleri (fr_user_properties). Kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer düşer;
  // geçerli özellik kalmazsa olay üretilmez (produced=false).
  TrackResult set_user_properties(const Properties& properties, const TrackOptions& options = {});
  TrackResult set_user_properties_value(const Value& properties, const TrackOptions& options = {});
  // Yakalanan (try/catch) istisnayı fr_error olarak bildirir: tür adı, temizlenmiş mesaj ve parmak izi; origin "handled".
  // C++ istisnası taşınabilir yığın izi taşımaz: çerçeve listesi boştur, parmak izi tür ve rakamsız mesajdan kurulur.
  // Süreç başına en çok 20 olay, aynı parmak izi için 3; error_sample_rate uygulanır. Sınıra takılırsa produced=false.
  TrackResult capture_error(const std::exception& error, const TrackOptions& options = {});
  // Elle kurulan hata raporu (ör. boost::stacktrace ile normalize çerçeveler). origin: handled, manual veya uncaught_exception.
  TrackResult capture_error(const ErrorReport& report, const TrackOptions& options = {});
  // Kuyruktaki olayları batch'ler hâlinde gönderir; geri çekilme beklemez.
  FlushResult flush();
  // Arka plan göndericiyi durdurur, kalan olayları en fazla timeout_ms içinde göndermeyi dener. İkinci çağrı boş sonuç döner.
  FlushResult close(int timeout_ms = wire::kCloseTimeoutMs);
  std::size_t queue_length() const;
  ClientStatus status() const;

 private:
  struct Impl;
  explicit Client(std::unique_ptr<Impl> impl);
  std::unique_ptr<Impl> impl_;
};

}  // namespace feralin

#endif  // FERALIN_HPP
