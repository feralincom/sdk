// Kararlı C API: C++ istemcisinin ince sarmalayıcısı. Hiçbir istisna bu sınırdan dışarı çıkmaz.
#include <cstring>
#include <new>

#include "feralin/feralin.h"
#include "feralin/feralin.hpp"

struct feralin_props {
  feralin::Value value = feralin::Value::make_object();
};

struct feralin_client {
  std::unique_ptr<feralin::Client> client;
};

namespace {

thread_local std::string g_last_error;

feralin_status status_of(feralin::ErrorCode code) {
  switch (code) {
    case feralin::ErrorCode::none: return FERALIN_OK;
    case feralin::ErrorCode::configuration: return FERALIN_ERR_CONFIGURATION;
    case feralin::ErrorCode::invalid_event: return FERALIN_ERR_INVALID_EVENT;
    case feralin::ErrorCode::client_closed: return FERALIN_ERR_CLOSED;
    case feralin::ErrorCode::rejected: return FERALIN_ERR_REJECTED;
    case feralin::ErrorCode::temporary: return FERALIN_ERR_TEMPORARY;
  }
  return FERALIN_ERR_INTERNAL;
}

feralin_status fail(feralin_status status, const std::string& message) {
  try {
    g_last_error = message;
  } catch (...) {
    // Bellek yoksa son hata metni güncellenmez; durum kodu yine doğru döner.
  }
  return status;
}

feralin_status report(const feralin::Error& error) {
  if (!error.failed()) return FERALIN_OK;
  return fail(status_of(error.code), error.message);
}

// İstisna sınırı: her giriş noktası bunun içinden geçer.
template <typename Body>
feralin_status guarded(Body&& body) {
  try {
    return body();
  } catch (const std::bad_alloc&) {
    return fail(FERALIN_ERR_INTERNAL, "bellek yetersiz");
  } catch (const std::exception&) {
    return fail(FERALIN_ERR_INTERNAL, "beklenmeyen iç hata");
  } catch (...) {
    return fail(FERALIN_ERR_INTERNAL, "beklenmeyen iç hata");
  }
}

std::string text_of(const char* value) { return value != nullptr ? std::string(value) : std::string(); }

feralin::Consent consent_of(unsigned int flags) {
  feralin::Consent consent;
  consent.analytics = (flags & FERALIN_CONSENT_ANALYTICS) != 0;
  consent.advertising = (flags & FERALIN_CONSENT_ADVERTISING) != 0;
  consent.personalization = (flags & FERALIN_CONSENT_PERSONALIZATION) != 0;
  consent.session_replay = (flags & FERALIN_CONSENT_SESSION_REPLAY) != 0;
  return consent;
}

// Çok baytlı karakteri ortadan kesmeden sabit tampona kopyalar.
void copy_text(char* target, std::size_t capacity, const std::string& text) {
  std::size_t length = std::min(text.size(), capacity - 1);
  while (length > 0 && length < text.size() && (static_cast<unsigned char>(text[length]) & 0xC0u) == 0x80u) --length;
  std::memcpy(target, text.data(), length);
  target[length] = '\0';
}

void write_flush_result(const feralin::FlushResult& result, feralin_flush_result* out) {
  if (out == nullptr) return;
  out->sent = result.sent;
  out->accepted = result.accepted;
  out->rejected = result.rejected;
  out->retained = result.retained;
  out->http_status = result.status;
  copy_text(out->batch_id, sizeof(out->batch_id), result.batch_id);
  copy_text(out->error, sizeof(out->error), result.error.message);
}

class CallbackTransport final : public feralin::Transport {
 public:
  CallbackTransport(feralin_transport_fn function, void* user_data) : function_(function), user_data_(user_data) {}

  feralin::HttpResponse post(const feralin::HttpRequest& request) override {
    std::vector<feralin_http_header> headers;
    headers.reserve(request.headers.size());
    for (const auto& header : request.headers) headers.push_back(feralin_http_header{header.first.c_str(), header.second.c_str()});
    feralin_http_request raw_request{request.url.c_str(), request.body.data(), request.body.size(), headers.data(), headers.size(), request.timeout_ms};

    std::string buffer(feralin::wire::kMaxResponseBody, '\0');
    feralin_http_response raw_response{0, &buffer[0], buffer.size(), 0, 0};
    feralin::HttpResponse response;
    if (function_(user_data_, &raw_request, &raw_response) != 0 || raw_response.status == 0) {
      response.error = "transport işlevi hata döndü";
      return response;
    }
    response.status = raw_response.status;
    response.body.assign(buffer.data(), std::min(raw_response.body_length, buffer.size()));
    if (raw_response.retry_after_seconds > 0) response.retry_after = std::to_string(raw_response.retry_after_seconds);
    return response;
  }

 private:
  feralin_transport_fn function_;
  void* user_data_;
};

// struct_size eski sürümle derlenmiş çağıranın yapısındaki son alanı gösterir; o alan yoksa varsayılan geçerlidir.
template <typename Struct, typename Field>
bool has_field(const Struct* value, const Field Struct::*member) {
  const auto* base = reinterpret_cast<const char*>(value);
  const auto* field = reinterpret_cast<const char*>(&(value->*member));
  return static_cast<std::size_t>(field - base) + sizeof(Field) <= value->struct_size;
}

void clear_track_result(feralin_track_result* out_result) {
  if (out_result == nullptr) return;
  out_result->produced = 0;
  out_result->event_id[0] = '\0';
}

// NULL seçenek: varsayılanlar. Başlatılmamış yapı yapılandırma hatasıdır.
feralin_status convert_track_options(const feralin_track_options* options, feralin::TrackOptions& cpp) {
  if (options == nullptr) return FERALIN_OK;
  if (options->struct_size == 0 || !has_field(options, &feralin_track_options::screen_height)) {
    return fail(FERALIN_ERR_CONFIGURATION, "feralin_track_options_init çağrılmadı");
  }
  cpp.user_id = text_of(options->user_id);
  cpp.anonymous_id = text_of(options->anonymous_id);
  cpp.session_id = text_of(options->session_id);
  if (options->has_occurred_at != 0) cpp.occurred_at_ms = options->occurred_at_ms;
  feralin::Context context;
  context.page_url = text_of(options->page_url);
  context.page_title = text_of(options->page_title);
  context.referrer = text_of(options->referrer);
  context.locale = text_of(options->locale);
  context.timezone = text_of(options->timezone);
  context.app_version = text_of(options->app_version);
  context.app_build = text_of(options->app_build);
  if (options->screen_width > 0 && options->screen_height > 0) context.screen = std::make_pair(options->screen_width, options->screen_height);
  cpp.context = std::move(context);
  return FERALIN_OK;
}

feralin_status finish_track(const feralin::TrackResult& result, feralin_track_result* out_result) {
  if (result.error.failed()) return report(result.error);
  if (out_result != nullptr && result.produced) {
    out_result->produced = 1;
    copy_text(out_result->event_id, sizeof(out_result->event_id), result.event_id);
  }
  return FERALIN_OK;
}

}  // namespace

extern "C" {

const char* feralin_version(void) { return FERALIN_SDK_VERSION; }

const char* feralin_status_name(feralin_status status) {
  switch (status) {
    case FERALIN_OK: return "FERALIN_OK";
    case FERALIN_ERR_CONFIGURATION: return "FERALIN_ERR_CONFIGURATION";
    case FERALIN_ERR_INVALID_EVENT: return "FERALIN_ERR_INVALID_EVENT";
    case FERALIN_ERR_CLOSED: return "FERALIN_ERR_CLOSED";
    case FERALIN_ERR_REJECTED: return "FERALIN_ERR_REJECTED";
    case FERALIN_ERR_TEMPORARY: return "FERALIN_ERR_TEMPORARY";
    case FERALIN_ERR_INTERNAL: return "FERALIN_ERR_INTERNAL";
  }
  return "FERALIN_ERR_UNKNOWN";
}

const char* feralin_last_error(void) { return g_last_error.c_str(); }

void feralin_options_init(feralin_options* options) {
  if (options == nullptr) return;
  std::memset(options, 0, sizeof(*options));
  options->struct_size = sizeof(*options);
  options->flush_interval_ms = feralin::wire::kDefaultFlushIntervalMs;
  options->batch_size = feralin::wire::kDefaultBatchSize;
  options->queue_limit = feralin::wire::kDefaultQueueLimit;
  options->timeout_ms = feralin::wire::kDefaultTimeoutMs;
  options->error_sample_rate = 1.0;
}

void feralin_track_options_init(feralin_track_options* options) {
  if (options == nullptr) return;
  std::memset(options, 0, sizeof(*options));
  options->struct_size = sizeof(*options);
}

void feralin_revenue_init(feralin_revenue* revenue) {
  if (revenue == nullptr) return;
  std::memset(revenue, 0, sizeof(*revenue));
  revenue->struct_size = sizeof(*revenue);
  revenue->quantity = 1;
}

feralin_status feralin_client_new(const feralin_options* options, feralin_client** out_client) {
  if (out_client == nullptr || options == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  *out_client = nullptr;
  if (options->struct_size == 0 || !has_field(options, &feralin_options::now_user_data)) {
    return fail(FERALIN_ERR_CONFIGURATION, "feralin_options_init çağrılmadı");
  }
  return guarded([&]() -> feralin_status {
    feralin::Options cpp;
    cpp.project_key = text_of(options->project_key);
    cpp.collect_url = text_of(options->collect_url);
    cpp.consent = consent_of(options->consent);
    cpp.flush_interval_ms = options->flush_interval_ms;
    cpp.batch_size = options->batch_size;
    cpp.queue_limit = options->queue_limit;
    cpp.timeout_ms = options->timeout_ms;
    // Eski sürümle derlenmiş yapıda bu alanlar yoktur; varsayılanlar geçerlidir.
    if (has_field(options, &feralin_options::app_version)) cpp.app_version = text_of(options->app_version);
    if (has_field(options, &feralin_options::error_sample_rate)) cpp.error_sample_rate = options->error_sample_rate;
    if (options->transport != nullptr) cpp.transport = std::make_shared<CallbackTransport>(options->transport, options->transport_user_data);
    if (options->now_ms != nullptr) {
      const feralin_now_fn function = options->now_ms;
      void* const user_data = options->now_user_data;
      cpp.now_ms = [function, user_data] { return function(user_data); };
    }
    if (options->logger != nullptr) {
      const feralin_log_fn function = options->logger;
      void* const user_data = options->logger_user_data;
      cpp.logger = [function, user_data](feralin::LogLevel level, const std::string& message) { function(user_data, static_cast<int>(level), message.c_str()); };
    }
    feralin::Error error;
    std::unique_ptr<feralin::Client> client = feralin::Client::create(std::move(cpp), &error);
    if (!client) return report(error);
    auto holder = std::make_unique<feralin_client>();
    holder->client = std::move(client);
    *out_client = holder.release();
    return FERALIN_OK;
  });
}

void feralin_client_free(feralin_client* client) {
  try {
    delete client;
  } catch (...) {
    // Yıkıcı istisna fırlatmaz; C sınırı yine de korunur.
  }
}

feralin_status feralin_set_consent(feralin_client* client, unsigned int consent) {
  if (client == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  return guarded([&]() -> feralin_status {
    client->client->set_consent(consent_of(consent));
    return FERALIN_OK;
  });
}

feralin_status feralin_identify(feralin_client* client, const char* user_id) {
  if (client == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  return guarded([&]() -> feralin_status { return report(client->client->identify(text_of(user_id))); });
}

feralin_status feralin_track(feralin_client* client, const char* event_name, const feralin_props* properties, const feralin_track_options* options, feralin_track_result* out_result) {
  if (client == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  clear_track_result(out_result);
  return guarded([&]() -> feralin_status {
    feralin::TrackOptions cpp;
    const feralin_status converted = convert_track_options(options, cpp);
    if (converted != FERALIN_OK) return converted;
    const feralin::Value empty;
    return finish_track(client->client->track_value(text_of(event_name), properties != nullptr ? properties->value : empty, cpp), out_result);
  });
}

feralin_status feralin_track_revenue(feralin_client* client, const feralin_revenue* revenue, const feralin_track_options* options, feralin_track_result* out_result) {
  if (client == nullptr || revenue == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  clear_track_result(out_result);
  if (revenue->struct_size == 0 || !has_field(revenue, &feralin_revenue::properties)) return fail(FERALIN_ERR_CONFIGURATION, "feralin_revenue_init çağrılmadı");
  return guarded([&]() -> feralin_status {
    feralin::TrackOptions cpp;
    const feralin_status converted = convert_track_options(options, cpp);
    if (converted != FERALIN_OK) return converted;
    feralin::RevenueInput input;
    input.transaction_id = text_of(revenue->transaction_id);
    input.amount_minor = revenue->amount_minor;
    input.currency = text_of(revenue->currency);
    input.product_id = text_of(revenue->product_id);
    input.quantity = revenue->quantity;
    input.purchase_type = text_of(revenue->purchase_type);
    if (revenue->receipt_provider != nullptr) input.receipt = feralin::Receipt{text_of(revenue->receipt_provider), text_of(revenue->receipt_token)};
    if (revenue->properties != nullptr) input.properties = revenue->properties->value;
    return finish_track(client->client->track_revenue(input, cpp), out_result);
  });
}

feralin_status feralin_group(feralin_client* client, const char* group_id, const feralin_props* traits, const feralin_track_options* options, feralin_track_result* out_result) {
  if (client == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  clear_track_result(out_result);
  return guarded([&]() -> feralin_status {
    feralin::TrackOptions cpp;
    const feralin_status converted = convert_track_options(options, cpp);
    if (converted != FERALIN_OK) return converted;
    const feralin::Value empty;
    return finish_track(client->client->group_value(text_of(group_id), traits != nullptr ? traits->value : empty, cpp), out_result);
  });
}

feralin_status feralin_set_user_properties(feralin_client* client, const feralin_props* properties, const feralin_track_options* options, feralin_track_result* out_result) {
  if (client == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  clear_track_result(out_result);
  return guarded([&]() -> feralin_status {
    feralin::TrackOptions cpp;
    const feralin_status converted = convert_track_options(options, cpp);
    if (converted != FERALIN_OK) return converted;
    const feralin::Value empty;
    return finish_track(client->client->set_user_properties_value(properties != nullptr ? properties->value : empty, cpp), out_result);
  });
}

feralin_status feralin_capture_error(feralin_client* client, const char* error_type, const char* message, int origin, int fatal, const feralin_track_options* options,
                                     feralin_track_result* out_result) {
  if (client == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  clear_track_result(out_result);
  const char* origin_name = nullptr;
  switch (origin) {
    case FERALIN_ERROR_ORIGIN_HANDLED: origin_name = feralin::signals::kErrorOriginHandled; break;
    case FERALIN_ERROR_ORIGIN_MANUAL: origin_name = feralin::signals::kErrorOriginManual; break;
    case FERALIN_ERROR_ORIGIN_UNCAUGHT: origin_name = feralin::signals::kErrorOriginUncaught; break;
    default: return fail(FERALIN_ERR_INVALID_EVENT, "origin FERALIN_ERROR_ORIGIN_* olmalı");
  }
  return guarded([&]() -> feralin_status {
    feralin::TrackOptions cpp;
    const feralin_status converted = convert_track_options(options, cpp);
    if (converted != FERALIN_OK) return converted;
    feralin::ErrorReport report;
    report.error_type = text_of(error_type);
    report.message = text_of(message);
    report.origin = origin_name;
    report.fatal = fatal != 0;
    return finish_track(client->client->capture_error(report, cpp), out_result);
  });
}

feralin_status feralin_flush(feralin_client* client, feralin_flush_result* out_result) {
  if (client == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  return guarded([&]() -> feralin_status {
    const feralin::FlushResult result = client->client->flush();
    write_flush_result(result, out_result);
    return report(result.error);
  });
}

feralin_status feralin_close(feralin_client* client, int timeout_ms, feralin_flush_result* out_result) {
  if (client == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  return guarded([&]() -> feralin_status {
    const feralin::FlushResult result = client->client->close(timeout_ms);
    write_flush_result(result, out_result);
    return report(result.error);
  });
}

size_t feralin_queue_length(feralin_client* client) {
  if (client == nullptr) return 0;
  try {
    return client->client->queue_length();
  } catch (...) {
    return 0;
  }
}

int64_t feralin_dropped_count(feralin_client* client) {
  if (client == nullptr) return 0;
  try {
    return client->client->status().dropped;
  } catch (...) {
    return 0;
  }
}

feralin_props* feralin_props_new(void) { return new (std::nothrow) feralin_props(); }

void feralin_props_free(feralin_props* properties) { delete properties; }

feralin_status feralin_props_set_string(feralin_props* properties, const char* key, const char* value) {
  if (properties == nullptr || key == nullptr || value == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  return guarded([&]() -> feralin_status {
    properties->value.set(key, feralin::Value(std::string(value)));
    return FERALIN_OK;
  });
}

feralin_status feralin_props_set_int(feralin_props* properties, const char* key, int64_t value) {
  if (properties == nullptr || key == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  return guarded([&]() -> feralin_status {
    properties->value.set(key, feralin::Value(value));
    return FERALIN_OK;
  });
}

feralin_status feralin_props_set_double(feralin_props* properties, const char* key, double value) {
  if (properties == nullptr || key == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  return guarded([&]() -> feralin_status {
    properties->value.set(key, feralin::Value(value));
    return FERALIN_OK;
  });
}

feralin_status feralin_props_set_bool(feralin_props* properties, const char* key, int value) {
  if (properties == nullptr || key == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  return guarded([&]() -> feralin_status {
    properties->value.set(key, feralin::Value(value != 0));
    return FERALIN_OK;
  });
}

feralin_status feralin_props_set_json(feralin_props* properties, const char* key, const char* value_json) {
  if (properties == nullptr || key == nullptr || value_json == nullptr) return fail(FERALIN_ERR_INTERNAL, "NULL argüman");
  return guarded([&]() -> feralin_status {
    feralin::Value parsed;
    if (!feralin::wire::parse_json(value_json, parsed)) return fail(FERALIN_ERR_INVALID_EVENT, "value_json geçerli JSON değil");
    properties->value.set(key, std::move(parsed));
    return FERALIN_OK;
  });
}

}  // extern "C"
