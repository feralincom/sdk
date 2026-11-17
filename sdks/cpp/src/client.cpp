// İş parçacığı ve ağ katmanı. Üretim ve teslim kuralları wire::EventCore içindedir.
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <exception>
#include <mutex>
#include <random>
#include <system_error>
#include <thread>
#include <typeinfo>

#if defined(__GNUG__) || defined(__clang__)
#include <cxxabi.h>
#include <cstdlib>
#endif

#include "feralin/feralin.hpp"

namespace feralin {

namespace {

std::int64_t system_now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
}

std::int64_t monotonic_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

// ULID'in rastgele kısmı gizli değildir; işletim sistemi kaynağı yoksa saat ile tohumlanmış üreteç yeterlidir.
void fill_random(unsigned char* buffer, std::size_t length) {
  static thread_local std::mt19937_64 fallback(static_cast<std::uint64_t>(monotonic_ms()) ^ static_cast<std::uint64_t>(std::hash<std::thread::id>{}(std::this_thread::get_id())));
  try {
    std::random_device device;
    for (std::size_t i = 0; i < length; ++i) buffer[i] = static_cast<unsigned char>(device() & 0xFFu);
  } catch (const std::exception&) {
    for (std::size_t i = 0; i < length; ++i) buffer[i] = static_cast<unsigned char>(fallback() & 0xFFu);
  }
}

// Çözülmüş tür adından son bileşen: şablon argümanı ve ad alanı atılır ("class std::runtime_error" → "runtime_error").
std::string last_type_segment(std::string name) {
  for (const char* prefix : {"class ", "struct "}) {
    const std::string tag(prefix);
    if (name.compare(0, tag.size(), tag) == 0) name.erase(0, tag.size());
  }
  const std::size_t angle = name.find('<');
  if (angle != std::string::npos) name.erase(angle);
  const std::size_t colon = name.rfind("::");
  if (colon != std::string::npos) name.erase(0, colon + 2);
  return name;
}

}  // namespace

std::string error_type_name(const std::exception& error) {
#if defined(__cpp_rtti) || defined(__GXX_RTTI) || defined(_CPPRTTI)
  const char* raw = typeid(error).name();
  std::string name = raw != nullptr ? raw : "";
#if defined(__GNUG__) || defined(__clang__)
  int status = 0;
  char* demangled = abi::__cxa_demangle(raw, nullptr, nullptr, &status);
  if (status == 0 && demangled != nullptr) name = demangled;
  std::free(demangled);
#endif
  name = last_type_segment(name);
  return name.empty() ? std::string("Error") : name;
#else
  (void)error;
  return "Error";
#endif
}

struct Client::Impl {
  Impl(Options&& opts, std::string key, std::string target, std::shared_ptr<Transport> http)
      : project_key(std::move(key)),
        endpoint(std::move(target)),
        timeout_ms(opts.timeout_ms),
        flush_interval_ms(opts.flush_interval_ms),
        transport(std::move(http)),
        now_ms(opts.now_ms ? std::move(opts.now_ms) : std::function<std::int64_t()>(system_now_ms)),
        logger(std::move(opts.logger)),
        app_version(std::move(opts.app_version)),
        error_limiter(opts.error_sample_rate),
        error_random(static_cast<std::uint64_t>(monotonic_ms())),
        core(wire::SdkIdentity{kSdkName, kSdkVersion, kPlatform}, opts.batch_size, opts.queue_limit, opts.consent) {}

  void log(LogLevel level, const std::string& message) const {
    if (!logger) return;
    try {
      logger(level, message);
    } catch (...) {
      // Uygulamanın log işleyicisi göndericiyi durduramaz.
    }
  }

  FlushResult send_one(const wire::Batch& batch, int request_timeout_ms) {
    HttpRequest request;
    request.url = endpoint;
    request.timeout_ms = request_timeout_ms;
    request.headers = wire::request_headers(project_key, wire::EventCore::batch_key(batch), core.identity());
    request.body = wire::EventCore::batch_body(batch, now_ms());

    HttpResponse response;
    try {
      response = transport->post(request);
    } catch (const std::exception&) {
      response = HttpResponse();
      response.error = "transport istisna fırlattı";
    } catch (...) {
      response = HttpResponse();
      response.error = "transport istisna fırlattı";
    }

    const std::int64_t now = monotonic_ms();
    FlushResult result;
    {
      std::lock_guard<std::mutex> guard(mutex);
      if (response.status == 0) {
        result = core.on_network_error(batch, response.error.empty() ? std::string("bağlantı kurulamadı") : response.error, now);
      } else {
        result = core.on_response(batch, response.status, response.body, response.retry_after, now);
      }
    }
    if (result.error.code == ErrorCode::rejected) {
      log(LogLevel::warning, "batch kalıcı olarak reddedildi: " + result.error.message);
    } else if (result.error.code == ErrorCode::temporary) {
      log(LogLevel::debug, "batch kuyrukta tutuldu: " + result.error.message);
    }
    return result;
  }

  // Aynı anda tek gönderici: sabit Idempotency-Key için. deadline_ms < 0 ise süre sınırı yok.
  FlushResult flush_all(std::int64_t deadline_ms) {
    std::lock_guard<std::mutex> sending(send_mutex);
    FlushResult total;
    int rounds = 0;
    {
      std::lock_guard<std::mutex> guard(mutex);
      rounds = core.max_rounds();
    }
    for (int round = 0; round < rounds; ++round) {
      wire::Batch batch;
      {
        std::lock_guard<std::mutex> guard(mutex);
        batch = core.peek();
      }
      if (batch.empty()) break;
      int request_timeout = timeout_ms;
      if (deadline_ms >= 0) {
        const std::int64_t remaining = deadline_ms - monotonic_ms();
        if (remaining <= 0) {
          total.error = wire::make_error(ErrorCode::temporary, "kapanış zaman aşımı; olaylar gönderilemedi");
          break;
        }
        request_timeout = static_cast<int>(std::min<std::int64_t>(request_timeout, remaining));
      }
      const FlushResult result = send_one(batch, request_timeout);
      total.sent += result.sent;
      total.accepted += result.accepted;
      total.rejected += result.rejected;
      total.status = result.status;
      if (!result.batch_id.empty()) total.batch_id = result.batch_id;
      if (result.error.failed()) {
        total.error = result.error;
        break;
      }
    }
    {
      std::lock_guard<std::mutex> guard(mutex);
      total.retained = static_cast<int>(core.queued());
    }
    return total;
  }

  // Arka plan gönderici: aralık dolunca veya kuyruk batch boyutuna ulaşınca gönderir, geri çekilmeye uyar.
  void run() {
    std::unique_lock<std::mutex> lock(mutex);
    for (;;) {
      wake_cv.wait_for(lock, std::chrono::milliseconds(flush_interval_ms), [this] { return wake || stop; });
      wake = false;
      if (stop) return;
      if (core.in_backoff(monotonic_ms())) continue;
      lock.unlock();
      try {
        flush_all(-1);
      } catch (...) {
        // Arka plan iş parçacığı ölmesin; olaylar kuyrukta kalır.
        log(LogLevel::failure, "arka plan gönderim hatası");
      }
      lock.lock();
    }
  }

  const std::string project_key;
  const std::string endpoint;
  const int timeout_ms;
  const int flush_interval_ms;
  const std::shared_ptr<Transport> transport;
  const std::function<std::int64_t()> now_ms;
  const std::function<void(LogLevel, const std::string&)> logger;
  const std::string app_version;

  mutable std::mutex mutex;  // çekirdek, closed, wake, stop, hata sınırı
  signals::ErrorLimiter error_limiter;
  std::mt19937_64 error_random;
  std::mutex send_mutex;
  std::condition_variable wake_cv;
  wire::EventCore core;
  bool closed = false;
  bool wake = false;
  bool stop = false;
  std::thread worker;
};

std::unique_ptr<Client> Client::create(Options options, Error* error) {
  const auto fail = [error](Error failure) -> std::unique_ptr<Client> {
    if (error != nullptr) *error = std::move(failure);
    return nullptr;
  };
  if (error != nullptr) *error = Error();

  std::string key;
  Error failure = wire::normalize_project_key(options.project_key, key);
  if (failure.failed()) return fail(failure);
  std::string endpoint;
  failure = wire::collect_endpoint(options.collect_url, endpoint);
  if (failure.failed()) return fail(failure);
  if (options.timeout_ms <= 0) return fail(wire::make_error(ErrorCode::configuration, "timeout pozitif olmalı"));
  std::shared_ptr<Transport> http = options.transport ? options.transport : default_transport();
  if (!http) return fail(wire::make_error(ErrorCode::configuration, "HTTP katmanı yok: FERALIN_TRANSPORT=NONE ile derlendi, Options::transport verin"));

  std::unique_ptr<Client> client(new Client(std::make_unique<Impl>(std::move(options), std::move(key), std::move(endpoint), std::move(http))));
  if (client->impl_->flush_interval_ms > 0) {
    try {
      Impl* self = client->impl_.get();
      self->worker = std::thread([self] { self->run(); });
    } catch (const std::system_error&) {
      return fail(wire::make_error(ErrorCode::configuration, "arka plan iş parçacığı açılamadı"));
    }
  }
  return client;
}

Client::Client(std::unique_ptr<Impl> impl) : impl_(std::move(impl)) {}

Client::~Client() { close(); }

void Client::set_consent(const Consent& consent) {
  std::lock_guard<std::mutex> guard(impl_->mutex);
  impl_->core.set_consent(consent);
}

Error Client::identify(const std::string& user_id) {
  std::lock_guard<std::mutex> guard(impl_->mutex);
  return impl_->core.identify(user_id);
}

TrackResult Client::track(const std::string& event_name, const Properties& properties, const TrackOptions& options) {
  return track_value(event_name, wire::properties_to_value(properties), options);
}

TrackResult Client::track_value(const std::string& event_name, const Value& properties, const TrackOptions& options) {
  TrackResult out;
  wire::TrackOutcome outcome;
  bool wake_worker = false;
  {
    std::lock_guard<std::mutex> guard(impl_->mutex);
    if (impl_->closed) {
      out.error = wire::make_error(ErrorCode::client_closed, "istemci kapatıldı");
      return out;
    }
    outcome = impl_->core.track(event_name, properties, options, impl_->now_ms(), fill_random);
    if (outcome.queue_full && impl_->worker.joinable()) {
      impl_->wake = true;
      wake_worker = true;
    }
  }
  if (wake_worker) impl_->wake_cv.notify_all();
  if (outcome.dropped_now > 0) {
    impl_->log(LogLevel::warning, "kuyruk sınırı aşıldı, en eski " + std::to_string(outcome.dropped_now) + " olay atıldı");
  }
  out.error = std::move(outcome.error);
  out.produced = outcome.produced;
  out.event_id = std::move(outcome.event_id);
  out.event_json = std::move(outcome.event_json);
  return out;
}

TrackResult Client::track_revenue(const RevenueInput& input, const TrackOptions& options) {
  const std::optional<Value> props = signals::revenue_properties(input);
  if (!props) {
    TrackResult out;
    out.error = wire::make_error(ErrorCode::invalid_event,
                                 "gelir girdisi geçersiz (transaction_id 1-128, amount_minor küçük birimde 0..2^53-1 tam sayı, currency ISO 4217, quantity 0..100000, purchase_type, receipt)");
    return out;
  }
  return track_value(signals::kRevenueEventName, *props, options);
}

TrackResult Client::group(const std::string& group_id, const Properties& traits, const TrackOptions& options) {
  return group_value(group_id, wire::properties_to_value(traits), options);
}

TrackResult Client::group_value(const std::string& group_id, const Value& traits, const TrackOptions& options) {
  if (!signals::valid_group_id(group_id)) {
    impl_->log(LogLevel::warning, "fr_group: geçersiz group_id, olay üretilmedi");
    return TrackResult();
  }
  Value props = signals::sanitize_profile_properties(traits);
  props.set("group_id", group_id);
  return track_value(signals::kGroupEventName, props, options);
}

TrackResult Client::set_user_properties(const Properties& properties, const TrackOptions& options) {
  return set_user_properties_value(wire::properties_to_value(properties), options);
}

TrackResult Client::set_user_properties_value(const Value& properties, const TrackOptions& options) {
  const Value clean = signals::sanitize_profile_properties(properties);
  if (clean.size() == 0) {
    impl_->log(LogLevel::warning, "fr_user_properties: geçerli özellik yok, olay üretilmedi");
    return TrackResult();
  }
  return track_value(signals::kUserPropertiesEventName, clean, options);
}

TrackResult Client::capture_error(const std::exception& error, const TrackOptions& options) {
  ErrorReport report;
  report.error_type = error_type_name(error);
  const char* what = error.what();
  report.message = what != nullptr ? what : "";
  report.origin = signals::kErrorOriginHandled;
  return capture_error(report, options);
}

TrackResult Client::capture_error(const ErrorReport& report, const TrackOptions& options) {
  if (!signals::known_error_origin(report.origin)) {
    TrackResult out;
    out.error = wire::make_error(ErrorCode::invalid_event, "fr_error origin handled, manual veya uncaught_exception olmalı");
    return out;
  }
  const Value props = signals::error_properties(report, impl_->app_version);
  {
    std::lock_guard<std::mutex> guard(impl_->mutex);
    // Kapalı istemcide track_value client_closed döner. İzin yoksa sınır sayacı harcanmaz; olay zaten üretilmez.
    if (!impl_->closed) {
      if (!impl_->core.consent().analytics) return TrackResult();
      const double unit = std::generate_canonical<double, 53>(impl_->error_random);
      if (!impl_->error_limiter.allow(props.find("fingerprint")->as_string(), unit)) return TrackResult();
    }
  }
  return track_value(signals::kErrorEventName, props, options);
}

FlushResult Client::flush() {
  {
    std::lock_guard<std::mutex> guard(impl_->mutex);
    if (impl_->closed) {
      FlushResult result;
      result.error = wire::make_error(ErrorCode::client_closed, "istemci kapatıldı");
      return result;
    }
  }
  return impl_->flush_all(-1);
}

FlushResult Client::close(int timeout_ms) {
  {
    std::lock_guard<std::mutex> guard(impl_->mutex);
    if (impl_->closed) return FlushResult();
    impl_->closed = true;
    impl_->stop = true;
  }
  impl_->wake_cv.notify_all();
  if (impl_->worker.joinable()) impl_->worker.join();
  return impl_->flush_all(monotonic_ms() + std::max(0, timeout_ms));
}

std::size_t Client::queue_length() const {
  std::lock_guard<std::mutex> guard(impl_->mutex);
  return impl_->core.queued();
}

ClientStatus Client::status() const {
  std::lock_guard<std::mutex> guard(impl_->mutex);
  ClientStatus out;
  out.sdk = kSdkName;
  out.version = kSdkVersion;
  out.queued = impl_->core.queued();
  out.dropped = impl_->core.dropped();
  out.consent = impl_->core.consent();
  out.user_id = impl_->core.user_id();
  out.closed = impl_->closed;
  out.backoff_ms = impl_->core.backoff_ms();
  out.endpoint = impl_->endpoint;
  return out;
}

}  // namespace feralin
