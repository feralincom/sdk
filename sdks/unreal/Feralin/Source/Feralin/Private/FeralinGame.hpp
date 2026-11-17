// Oyun SDK'larının ortak olay sözleşmeleri ve istemci mantığı (motordan bağımsız, yalnız standart kütüphane).
//
// Sözleşme kaynağı Unity SDK 0.2.0'dır (sdks/unity/Runtime/Core): kalıcı şifreli kuyruk, feralin_purchase, fr_ad_revenue, fr_group,
// fr_user_properties, fr_error, oyun olayları (packages/schemas/utp/v1/game-events.md), 30 dakikalık otomatik oturum, izin kapısı,
// Play Install Referrer, AdServices BindInstall ve deep_link_opened. Motor katmanı (FeralinSubsystem.cpp) bu sınıfı sarar; ağ ve
// platform köprüleri enjekte edilir, böylece bütün mantık Unreal olmadan g++ ile sınanır.
//
// Eş zamanlılık: Client tek iş parçacığı (oyun iş parçacığı) içindir. Platform köprüleri başka iş parçacığından yanıt verirse
// motor katmanı çağrıyı oyun iş parçacığına taşır.
#ifndef FERALIN_GAME_HPP
#define FERALIN_GAME_HPP

#include <algorithm>
#include <cmath>
#include <deque>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "FeralinCrypto.hpp"
#include "FeralinSanitize.hpp"
#include "FeralinWire.hpp"

namespace feralin {
namespace game {

namespace w = wire;
using w::Value;

constexpr std::int64_t kMaxSafeInteger = (static_cast<std::int64_t>(1) << 53) - 1;
constexpr std::size_t kMaxEventChars = 256 * 1024;

// ---------------------------------------------------------------- özellik süzgeci

inline bool server_only_key(const std::string& key) {
  std::string lower_key = key;
  for (char& c : lower_key) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c + 32 : c);
  return lower_key == "verified" || lower_key == "tenant_id" || lower_key == "project_id";
}

// Şemaya uymayan, sunucuya ait ya da 100'ü aşan anahtar düşer (tek geçersiz alan toplayıcıda tüm batch'i düşürürdü).
inline Value sanitize_properties(const Value& properties) {
  Value out = Value::make_object();
  if (!properties.is_object()) return out;
  for (std::size_t i = 0; i < properties.size(); ++i) {
    const std::string& key = properties.key_at(i);
    if (!w::valid_property_key(key) || server_only_key(key) || out.size() >= w::kMaxProperties) continue;
    out.set(key, properties.at(i));
  }
  return out;
}

inline bool valid_currency(const std::string& value) {
  return value.size() == 3 && std::all_of(value.begin(), value.end(), [](char c) { return c >= 'A' && c <= 'Z'; });
}

inline bool text_in(const std::string& value, std::size_t max) {
  std::size_t length = 0;
  return !value.empty() && w::utf8_length(value, length) && length <= max;
}

inline bool optional_text(const std::optional<std::string>& value, std::size_t max) { return !value || text_in(*value, max); }

// ---------------------------------------------------------------- gelir (feralin_purchase)

enum class PurchaseType { purchase, subscription_start, subscription_renew, subscription_cancel };
enum class ReceiptProvider { apple, google, stripe };

inline const char* purchase_type_wire(PurchaseType t) {
  switch (t) {
    case PurchaseType::subscription_start: return "subscription_start";
    case PurchaseType::subscription_renew: return "subscription_renew";
    case PurchaseType::subscription_cancel: return "subscription_cancel";
    default: return "purchase";
  }
}

inline const char* receipt_provider_wire(ReceiptProvider p) {
  switch (p) {
    case ReceiptProvider::apple: return "apple";
    case ReceiptProvider::google: return "google";
    default: return "stripe";
  }
}

struct Receipt {
  ReceiptProvider provider = ReceiptProvider::apple;
  std::string token;
};

// İstemci beyanıdır: verified hiçbir zaman gönderilmez. Android, Flutter, React Native ve Unity ile aynı sözleşme.
struct RevenueInput {
  std::string transaction_id;
  std::int64_t amount_minor = 0;
  std::string currency;
  std::optional<std::string> product_id;
  int quantity = 1;
  PurchaseType purchase_type = PurchaseType::purchase;
  std::optional<Receipt> receipt;
  Value properties;
};

constexpr int kMaxQuantity = 100000;
constexpr std::size_t kMaxTokenLength = 8192;

// Sözleşme dışı girdide boş döner (olay üretilmez).
inline std::optional<Value> revenue_properties(const RevenueInput& in) {
  if (!text_in(in.transaction_id, w::kMaxIdentifierLength)) return std::nullopt;
  if (in.amount_minor < 0 || in.amount_minor > kMaxSafeInteger) return std::nullopt;
  if (!valid_currency(in.currency)) return std::nullopt;
  if (in.product_id && !text_in(*in.product_id, w::kMaxIdentifierLength)) return std::nullopt;
  if (in.quantity < 0 || in.quantity > kMaxQuantity) return std::nullopt;
  if (in.purchase_type == PurchaseType::subscription_cancel && in.amount_minor != 0) return std::nullopt;
  if (in.receipt) {
    std::size_t length = 0;
    if (in.receipt->token.empty() || !w::utf8_length(in.receipt->token, length) || length > kMaxTokenLength) return std::nullopt;
  }
  Value props = sanitize_properties(in.properties);
  for (const char* key : {"verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"}) props.erase(key);
  props.set("transaction_id", in.transaction_id);
  props.set("amount_minor", in.amount_minor);
  props.set("currency", in.currency);
  props.set("quantity", in.quantity);
  props.set("purchase_type", purchase_type_wire(in.purchase_type));
  if (in.product_id) props.set("product_id", *in.product_id);
  if (in.receipt) {
    Value receipt = Value::make_object();
    receipt.set("provider", receipt_provider_wire(in.receipt->provider));
    receipt.set("token", in.receipt->token);
    props.set("receipt", receipt);
  }
  return props;
}

// ISO 4217 küçük birim üssü: ondalık tutarı tam sayı küçük birime çevirir (yarım değer yukarı).
inline int currency_exponent(const std::string& currency) {
  static const std::set<std::string> zero = {"BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "UYI", "VND", "VUV", "XAF", "XOF", "XPF"};
  static const std::set<std::string> three = {"BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND"};
  return zero.count(currency) != 0 ? 0 : three.count(currency) != 0 ? 3 : 2;
}

inline std::optional<std::int64_t> to_minor(double amount, const std::string& currency) {
  if (!(amount >= 0)) return std::nullopt;
  double scale = 1;
  for (int i = 0; i < currency_exponent(currency); ++i) scale *= 10;
  const double minor = std::floor(amount * scale + 0.5);
  if (minor > static_cast<double>(kMaxSafeInteger)) return std::nullopt;
  return static_cast<std::int64_t>(minor);
}

// ---------------------------------------------------------------- reklam geliri (fr_ad_revenue)

enum class AdFormat { banner, interstitial, rewarded, rewarded_interstitial, native, app_open, other };
enum class AdPrecision { estimated, publisher_provided, precise, unknown };

inline const char* ad_format_wire(AdFormat f) {
  switch (f) {
    case AdFormat::banner: return "banner";
    case AdFormat::interstitial: return "interstitial";
    case AdFormat::rewarded: return "rewarded";
    case AdFormat::rewarded_interstitial: return "rewarded_interstitial";
    case AdFormat::native: return "native";
    case AdFormat::app_open: return "app_open";
    default: return "other";
  }
}

inline const char* ad_precision_wire(AdPrecision p) {
  switch (p) {
    case AdPrecision::estimated: return "estimated";
    case AdPrecision::publisher_provided: return "publisher_provided";
    case AdPrecision::precise: return "precise";
    default: return "unknown";
  }
}

struct AdRevenueInput {
  std::string network;  // ^[a-z][a-z0-9_]{0,63}$
  AdFormat ad_format = AdFormat::other;
  std::int64_t revenue_micros = 0;  // para biriminin milyonda biri, ondalık yok
  std::string currency;
  std::optional<std::string> ad_unit;
  AdPrecision precision = AdPrecision::unknown;
  std::optional<std::string> placement;
  std::optional<std::string> impression_id;
  Value properties;
};

inline bool valid_network(const std::string& n) {
  if (n.empty() || n.size() > 64 || !(n[0] >= 'a' && n[0] <= 'z')) return false;
  return std::all_of(n.begin(), n.end(), [](char c) { return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'; });
}

inline std::optional<Value> ad_revenue_properties(const AdRevenueInput& in) {
  if (!valid_network(in.network)) return std::nullopt;
  if (in.revenue_micros < 0 || in.revenue_micros > kMaxSafeInteger) return std::nullopt;
  if (!valid_currency(in.currency)) return std::nullopt;
  if (!optional_text(in.ad_unit, 128) || !optional_text(in.placement, 64) || !optional_text(in.impression_id, 128)) return std::nullopt;
  Value props = sanitize_properties(in.properties);
  for (const char* key : {"verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"}) props.erase(key);
  props.set("network", in.network);
  props.set("ad_format", ad_format_wire(in.ad_format));
  props.set("revenue_micros", in.revenue_micros);
  props.set("currency", in.currency);
  props.set("precision", ad_precision_wire(in.precision));
  if (in.ad_unit) props.set("ad_unit", *in.ad_unit);
  if (in.placement) props.set("placement", *in.placement);
  if (in.impression_id) props.set("impression_id", *in.impression_id);
  return props;
}

// ---------------------------------------------------------------- oyun olayları

constexpr std::int64_t kMaxDurationMs = 86400000;
constexpr std::int64_t kMaxEconomyAmount = 1000000000000;

// Yardımcılar özellik ekler; sözleşme dışında false döner. Kurallar game-events.md ile aynıdır.
struct GameProps {
  Value props;
  bool ok = true;
  explicit GameProps(const Value& extra) : props(sanitize_properties(extra)) {}

  GameProps& text(const char* key, const std::string& value, std::size_t max) {
    if (!text_in(value, max)) ok = false; else props.set(key, value);
    return *this;
  }
  GameProps& opt_text(const char* key, const std::optional<std::string>& value, std::size_t max) {
    if (!value) return *this;
    return text(key, *value, max);
  }
  GameProps& opt_number(const char* key, const std::optional<std::int64_t>& value, std::int64_t min, std::int64_t max) {
    if (!value) return *this;
    if (*value < min || *value > max) ok = false; else props.set(key, *value);
    return *this;
  }
};

inline std::optional<Value> level_properties(const std::string& level_id, std::optional<std::int64_t> attempt, std::optional<std::int64_t> score,
                                             std::optional<std::int64_t> duration_ms, const std::optional<std::string>& fail_reason, const Value& extra) {
  GameProps g(extra);
  g.text("level_id", level_id, 64).opt_number("attempt", attempt, 1, kMaxSafeInteger).opt_number("score", score, 0, kMaxSafeInteger)
      .opt_number("duration_ms", duration_ms, 0, kMaxDurationMs).opt_text("fail_reason", fail_reason, 64);
  if (!g.ok) return std::nullopt;
  return g.props;
}

inline std::optional<Value> economy_properties(const std::string& currency_name, std::int64_t amount, const std::optional<std::string>& reason,
                                               const std::optional<std::string>& item_id, const Value& extra) {
  GameProps g(extra);
  g.text("currency_name", currency_name, 64);
  if (amount < 1 || amount > kMaxEconomyAmount) g.ok = false; else g.props.set("amount", amount);
  g.opt_text("reason", reason, 64).opt_text("item_id", item_id, 64);
  if (!g.ok) return std::nullopt;
  return g.props;
}

inline std::optional<Value> rewarded_shown_properties(const std::string& placement, const std::optional<std::string>& network, const Value& extra) {
  GameProps g(extra);
  g.text("placement", placement, 64).opt_text("network", network, 64);
  if (!g.ok) return std::nullopt;
  return g.props;
}

inline std::optional<Value> rewarded_complete_properties(const std::string& placement, const std::optional<std::string>& network,
                                                         std::optional<std::int64_t> reward_amount, const std::optional<std::string>& reward_currency, const Value& extra) {
  GameProps g(extra);
  g.text("placement", placement, 64).opt_text("network", network, 64).opt_number("reward_amount", reward_amount, 0, kMaxSafeInteger).opt_text("reward_currency", reward_currency, 64);
  if (!g.ok) return std::nullopt;
  return g.props;
}

inline std::optional<Value> iap_offer_properties(const std::string& product_id, const std::optional<std::string>& placement, const Value& extra) {
  GameProps g(extra);
  g.text("product_id", product_id, 128).opt_text("placement", placement, 64);
  if (!g.ok) return std::nullopt;
  return g.props;
}

inline std::optional<Value> iap_initiated_properties(const std::string& product_id, const std::optional<std::string>& placement,
                                                     const std::optional<std::string>& transaction_id, const Value& extra) {
  GameProps g(extra);
  g.text("product_id", product_id, 128).opt_text("placement", placement, 64).opt_text("transaction_id", transaction_id, 128);
  if (!g.ok) return std::nullopt;
  return g.props;
}

// ---------------------------------------------------------------- atıf: fr_click, utm_* ve derin bağlantı

struct AttributionParams {
  std::string fr_click;
  std::vector<std::pair<std::string, std::string>> utm;
  std::string deep_link_path;

  bool empty() const { return fr_click.empty() && utm.empty(); }
  const std::string* utm_value(const std::string& key) const {
    for (const auto& pair : utm) if (pair.first == key) return &pair.second;
    return nullptr;
  }
  // Play'in tıklama yokken döndürdüğü varsayılan (organic / (not set)) kanıt sayılmaz.
  bool play_organic_default() const {
    if (!fr_click.empty()) return false;
    const std::string* medium = utm_value("utm_medium");
    const std::string* source = utm_value("utm_source");
    if (medium != nullptr) {
      std::string m = *medium;
      for (char& c : m) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c + 32 : c);
      if (m == "organic") return true;
    }
    return source != nullptr && *source == "(not set)";
  }
  void write_to(Value& target) const {
    if (!fr_click.empty()) target.set("fr_click", fr_click);
    for (const auto& pair : utm) target.set(pair.first, pair.second);
  }
};

// Katı çözümleme: '+' boşluktur, bozuk %XX ya da geçersiz UTF-8 boş döndürür (parça yok sayılır).
inline bool percent_decode(const std::string& text, std::string& out) {
  out.clear();
  for (std::size_t i = 0; i < text.size(); ++i) {
    const char c = text[i];
    if (c == '+') {
      out.push_back(' ');
    } else if (c == '%') {
      if (i + 2 >= text.size()) return false;
      const int hi = crypto::hex_value(text[i + 1]);
      const int lo = crypto::hex_value(text[i + 2]);
      if (hi < 0 || lo < 0) return false;
      out.push_back(static_cast<char>((hi << 4) | lo));
      i += 2;
    } else {
      out.push_back(c);
    }
  }
  return w::utf8_valid(out);
}

inline bool fr_click_valid(const std::string& v) {
  if (v.empty() || v.size() > 256) return false;
  return std::all_of(v.begin(), v.end(), [](char c) { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '~' || c == '-'; });
}

// Link-router ve saas-api ile aynı kural: şema ve host taşıyamaz, yalnız uygulama içi yol.
inline bool valid_deep_link_path(const std::string& path) {
  if (path.empty() || path.size() > 200 || path[0] != '/' || path.rfind("//", 0) == 0) return false;
  static const std::string allowed = "._~!$'()*+,;=:@%/?&-";
  for (const char c : path) {
    if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || allowed.find(c) != std::string::npos)) return false;
  }
  // Kodlanmış nokta, bölü, ters bölü, kontrol karakteri ya da bozuk kaçış: %2e%2e birleştirmede üst dizine çıkar.
  for (std::size_t i = 0; i < path.size(); ++i) {
    if (path[i] != '%') continue;
    if (i + 2 >= path.size()) return false;
    const int hi = crypto::hex_value(path[i + 1]);
    const int lo = crypto::hex_value(path[i + 2]);
    if (hi < 0 || lo < 0) return false;
    const int value = (hi << 4) | lo;
    if (value == 0x2e || value == 0x2f || value == 0x5c || value < 0x20 || value == 0x7f) return false;
  }
  const std::size_t question = path.find('?');
  const std::string only = question == std::string::npos ? path : path.substr(0, question);
  std::size_t start = 0;
  while (start <= only.size()) {
    std::size_t end = only.find('/', start);
    if (end == std::string::npos) end = only.size();
    if (only.substr(start, end - start) == "..") return false;
    start = end + 1;
  }
  return true;
}

inline AttributionParams parse_attribution_query(const std::string& raw) {
  AttributionParams result;
  std::string text = raw;
  const auto not_blank = [](const std::string& s) { return s.find_first_not_of(" \t\r\n") != std::string::npos; };
  if (!not_blank(text)) return result;
  // Bazı kampanya araçları referrer'ın tamamını bir kez daha kodlar.
  if (text.find('=') == std::string::npos && (text.find("%3D") != std::string::npos || text.find("%3d") != std::string::npos)) {
    std::string decoded;
    if (percent_decode(text, decoded)) text = decoded;
  }
  static const std::set<std::string> utm_keys = {"utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"};
  std::string deep_link;
  std::size_t start = 0;
  while (start <= text.size()) {
    std::size_t end = text.find('&', start);
    if (end == std::string::npos) end = text.size();
    const std::string pair = text.substr(start, end - start);
    start = end + 1;
    const std::size_t eq = pair.find('=');
    if (eq == std::string::npos || eq == 0) continue;
    std::string key;
    if (!percent_decode(pair.substr(0, eq), key)) continue;
    if (key != "fr_click" && key != "fr_dl" && utm_keys.count(key) == 0) continue;
    std::string value;
    if (!percent_decode(pair.substr(eq + 1), value)) continue;
    const std::size_t b = value.find_first_not_of(" \t\r\n");
    if (b == std::string::npos) continue;
    value = value.substr(b, value.find_last_not_of(" \t\r\n") - b + 1);
    if (key == "fr_click") {
      if (result.fr_click.empty() && fr_click_valid(value)) result.fr_click = value;
    } else if (key == "fr_dl") {
      if (deep_link.empty() && valid_deep_link_path(value)) deep_link = value;
    } else if (result.utm_value(key) == nullptr) {
      std::size_t length = 0;
      if (w::utf8_length(value, length) && length > 256) value = w::utf8_truncate(value, 256);
      result.utm.emplace_back(key, value);
    }
  }
  // Yol tıklama kimliğiyle birlikte gelir; kimliksiz değer Feralin linkinden gelmemiştir.
  if (!result.fr_click.empty()) result.deep_link_path = deep_link;
  return result;
}

struct DeepLink {
  std::string clean_url;
  AttributionParams params;
};

// Yalnız http(s) kabul edilir; özel şemalar kanıt sayılmaz. Sorgu ve parça olmadan temiz URL döner.
inline std::optional<DeepLink> parse_deep_link(const std::string& raw) {
  const std::size_t b = raw.find_first_not_of(" \t\r\n");
  if (b == std::string::npos) return std::nullopt;
  const std::string url = raw.substr(b, raw.find_last_not_of(" \t\r\n") - b + 1);
  const std::size_t scheme_end = url.find("://");
  if (scheme_end == std::string::npos) return std::nullopt;
  std::string scheme = url.substr(0, scheme_end);
  for (char& c : scheme) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c + 32 : c);
  if (scheme != "http" && scheme != "https") return std::nullopt;
  const std::size_t authority_start = scheme_end + 3;
  std::size_t authority_end = url.find_first_of("/?#", authority_start);
  if (authority_end == std::string::npos) authority_end = url.size();
  std::string authority = url.substr(authority_start, authority_end - authority_start);
  const std::size_t at = authority.rfind('@');
  if (at != std::string::npos) authority = authority.substr(at + 1);
  std::string host = authority;
  std::string port;
  const std::size_t colon = authority.rfind(':');
  if (colon != std::string::npos && authority.find(']') == std::string::npos) {
    host = authority.substr(0, colon);
    port = authority.substr(colon + 1);
    if (!std::all_of(port.begin(), port.end(), [](char c) { return c >= '0' && c <= '9'; })) return std::nullopt;
  }
  if (host.empty()) return std::nullopt;
  for (char& c : host) c = static_cast<char>(c >= 'A' && c <= 'Z' ? c + 32 : c);
  if ((scheme == "https" && port == "443") || (scheme == "http" && port == "80")) port.clear();
  std::string rest = url.substr(authority_end);
  const std::size_t hash = rest.find('#');
  if (hash != std::string::npos) rest = rest.substr(0, hash);
  const std::size_t question = rest.find('?');
  const std::string path = question == std::string::npos ? rest : rest.substr(0, question);
  const std::string query = question == std::string::npos ? std::string() : rest.substr(question + 1);
  DeepLink link;
  link.clean_url = scheme + "://" + host + (port.empty() ? "" : ":" + port) + (path.empty() ? "/" : path);
  if (link.clean_url.size() > 2048) return std::nullopt;
  link.params = parse_attribution_query(query);
  return link;
}

// ---------------------------------------------------------------- kurulum eşleştirme kodu (fr_install_code)

// Panelin ürettiği tek kullanımlık kod ilk olayla gider; toplayıcı kodu olaydan söker ve kurulumu eşleştirir (ClickHouse'a yazılmaz).
// Biçim packages/sdk-web/src/index.ts INSTALL_CODE_PATTERN, Android SDK ve services/collect/internal/worker/installcode.go ile aynı:
// ^[0-9A-HJKMNP-TV-Za-hjkmnp-tv-z _-]{10,16}$ (Crockford Base32: I, L, O, U yok; tire, boşluk ve alt çizgi ayraç).
constexpr const char* kInstallCodeProperty = "fr_install_code";

inline bool install_code_char(char c) {
  if (c >= '0' && c <= '9') return true;
  if (c == ' ' || c == '_' || c == '-') return true;
  const char upper = (c >= 'a' && c <= 'z') ? static_cast<char>(c - 'a' + 'A') : c;
  if (upper < 'A' || upper > 'Z') return false;
  return upper != 'I' && upper != 'L' && upper != 'O' && upper != 'U';
}

// Kırpılmış kodu döndürür; biçime uymayan değer boş döner (kod gönderilmez).
inline std::string normalize_install_code(const std::string& raw) {
  const std::string code = w::trim(raw);
  if (code.size() < 10 || code.size() > 16) return std::string();
  for (const char c : code) {
    if (!install_code_char(c)) return std::string();
  }
  return code;
}

// ---------------------------------------------------------------- hata yakalama

struct ErrorOptions {
  double sample_rate = 1.0;
  int max_per_minute = 10;
  int max_per_fingerprint_per_minute = 2;
  std::size_t max_message_length = 200;
  std::size_t max_frames = 12;
};

namespace error_source {
constexpr const char* manual = "manual";
constexpr const char* log_error = "log_error";            // motor günlüğünde Error düzeyi kayıt
constexpr const char* log_fatal = "log_fatal";            // motor günlüğünde Fatal kayıt ya da çökme işleyicisi
constexpr const char* unhandled_exception = "unhandled_exception";
}  // namespace error_source

inline const char* error_origin(const std::string& source, bool handled) {
  if (source == error_source::unhandled_exception || source == error_source::log_fatal) return "uncaught_exception";
  if (source == error_source::log_error) return "handled";
  return handled ? "manual" : "uncaught_exception";
}

// ---------------------------------------------------------------- platform köprüleri

enum class TrackingStatus { not_determined = 0, restricted = 1, denied = 2, authorized = 3, unavailable = 4 };

namespace install_status {
constexpr const char* received = "received";
constexpr const char* skipped_no_consent = "skipped_no_consent";
constexpr const char* not_configured = "not_configured";
constexpr const char* unsupported = "unsupported";
constexpr const char* token_unavailable = "token_unavailable";
constexpr const char* rejected = "rejected";
constexpr const char* temporary_failure = "temporary_failure";
}  // namespace install_status

struct InstallBinding {
  std::string status;
  std::string install_id;  // reklam izni yoksa boş
};

// Android: Play Install Referrer ham dizgisini bir kez verir (yoksa has=false). iOS: AdServices token'ı.
using ReferrerReader = std::function<void(std::function<void(bool has_value, const std::string& raw)>)>;
struct TokenResult {
  std::string status;  // token | unsupported | failed
  std::string token;
};
using TokenReader = std::function<void(std::function<void(const TokenResult&)>)>;
// Yanıt kodu 0 ise ağ hatası.
using HttpPost = std::function<void(const std::string& url, const w::Headers& headers, const std::string& body, std::function<void(int status)>)>;

struct Environment {
  std::function<std::int64_t()> now_ms;
  std::function<std::int64_t()> mono_ms;
  w::RandomFill fill;
  std::function<double()> unit_random;  // 0..1
  std::function<void(const std::string&)> log;
};

struct Options {
  w::SdkIdentity sdk;
  std::string project_key;
  std::string attribution_api_url;  // https://api.feralin.com
  std::string project_id;
  int batch_size = w::kDefaultBatchSize;
  int queue_limit = w::kDefaultQueueLimit;
  std::int64_t session_timeout_ms = 30 * 60 * 1000;
  ErrorOptions errors;
  std::function<TrackingStatus()> tracking_status;  // iOS ATT; yoksa reklam izni tek başına yeter
  std::string queue_protection;  // android_keystore | ios_keychain | local_file | none
  std::string install_code;      // panelin verdiği kurulum eşleştirme kodu; geçersizse yok sayılır
};

constexpr const char* kMarkerFirstOpen = "first_open_event_id";
constexpr const char* kMarkerFirstOpenAt = "first_open_at_ms";
constexpr const char* kMarkerReferrerChecked = "referrer_checked";
constexpr const char* kMarkerDeferredDeepLink = "deferred_deep_link";
constexpr const char* kMarkerInstallId = "install_id";

struct TrackResult {
  bool produced = false;
  bool queue_full = false;
  std::string event_id;
};

class Client {
 public:
  Client(Options options, Environment env, std::unique_ptr<crypto::EventStore> store)
      : options_(std::move(options)),
        env_(std::move(env)),
        store_(std::move(store)),
        core_(options_.sdk, options_.batch_size, options_.queue_limit, w::Consent()),
        pending_install_code_(normalize_install_code(options_.install_code)) {
    if (options_.session_timeout_ms > 0) session_id_ = new_ulid();
  }

  w::EventCore& core() { return core_; }
  const w::Consent& consent() const { return consent_; }
  bool persistent() const { return store_ != nullptr; }
  const std::string& queue_protection() const { return options_.queue_protection; }
  std::int64_t errors_suppressed() const { return errors_suppressed_; }
  const std::string& session_id() const { return session_id_; }
  void set_anonymous_id(const std::string& id) { anonymous_id_ = id; }
  const std::string& anonymous_id() const { return anonymous_id_; }
  // Henüz gönderilmemiş kurulum eşleştirme kodu (ilk üretilen olayla gider ve silinir).
  const std::string& pending_install_code() const { return pending_install_code_; }

  // Kurulum eşleştirme kodunu çalışma anında verir (ör. kurulum sihirbazında yapıştırılan kod). Biçime uymazsa false; bekleyen kod değişmez.
  bool set_install_code(const std::string& raw) {
    const std::string code = normalize_install_code(raw);
    if (code.empty()) return false;
    pending_install_code_ = code;
    return true;
  }

  // ------------------------------------------------------------ izin

  void set_consent(const w::Consent& next) {
    consent_ = next;
    consent_decided_ = true;
    apply_core_consent();
    if (!next.analytics) {
      order_.clear();
      if (store_) {
        store_->clear();
        store_->remove_marker(kMarkerInstallId);
        store_->remove_marker(kMarkerDeferredDeepLink);
      }
      store_loaded_ = false;
      link_evidence_.reset();
      first_open_started_ = false;
      follow_up_started_ = false;
      install_id_.clear();
    } else {
      load_persisted();
    }
    on_consent_applied();
  }

  // ------------------------------------------------------------ olay üretimi

  TrackResult track(const std::string& name, const Value& properties) { return track_with_page(name, properties, std::nullopt, std::string()); }

  TrackResult track_revenue(const RevenueInput& input) {
    const auto props = revenue_properties(input);
    if (!props) return reject("feralin_purchase");
    return track("feralin_purchase", *props);
  }

  TrackResult track_ad_revenue(const AdRevenueInput& input) {
    const auto props = ad_revenue_properties(input);
    if (!props) return reject("fr_ad_revenue");
    return track("fr_ad_revenue", *props);
  }

  // Eski iap_purchase yardımcısı: ondalık tutarı küçük birime çevirip feralin_purchase gönderir; işlem kimliği zorunludur.
  TrackResult track_iap_purchase(const std::string& product_id, double price, const std::string& currency, const std::string& transaction_id, const Value& properties) {
    const auto minor = valid_currency(currency) ? to_minor(price, currency) : std::nullopt;
    if (product_id.empty() || transaction_id.empty() || !minor) return reject("iap_purchase");
    RevenueInput input;
    input.transaction_id = transaction_id;
    input.amount_minor = *minor;
    input.currency = currency;
    input.product_id = product_id;
    input.properties = properties;
    return track_revenue(input);
  }

  TrackResult group(const std::string& group_id, const Value& traits) {
    if (!text_in(group_id, w::kMaxIdentifierLength)) return reject("fr_group");
    Value props = sanitize_properties(traits);
    props.set("group_id", group_id);
    return track("fr_group", props);
  }

  TrackResult set_user_properties(const Value& properties) {
    const Value props = sanitize_properties(properties);
    if (props.size() == 0) return reject("fr_user_properties");
    return track("fr_user_properties", props);
  }

  TrackResult track_game(const char* name, const std::optional<Value>& props) {
    if (!props) return reject(name);
    return track(name, *props);
  }

  // fr_error: ileti ve yığın kişisel veriden arındırılır, çerçeveler normalleştirilir, parmak izi üretilir; örnekleme ve hız sınırı uygulanır.
  TrackResult capture_error(const std::string& error_type, const std::string& message, const std::string& stack_trace, bool handled, const std::string& source) {
    TrackResult none;
    if (!consent_.analytics) return none;
    const ErrorOptions& o = options_.errors;
    if (o.sample_rate <= 0 || (o.sample_rate < 1 && env_.unit_random() >= o.sample_rate)) return none;
    std::string type = sanitize::scrub(error_type.empty() ? "Error" : error_type, 64);
    if (type.empty()) type = "Error";
    const auto frames = sanitize::normalize_frames(stack_trace, std::max<std::size_t>(1, o.max_frames));
    const std::string fingerprint = sanitize::fingerprint(type, frames);
    if (!admit_error(fingerprint)) {
      ++errors_suppressed_;
      return none;
    }
    // Alan adları ve türleri packages/schemas/utp/v1/event.schema.json fr_error ile aynıdır; toplayıcı bunun dışındaki alanı düşürür.
    Value props = Value::make_object();
    props.set("error_type", type);
    props.set("fingerprint", fingerprint);
    props.set("frame_count", static_cast<std::int64_t>(frames.size()));
    props.set("handled", handled);
    props.set("fatal", source == error_source::unhandled_exception || source == error_source::log_fatal);
    props.set("origin", error_origin(source, handled));
    const std::string clean = sanitize::scrub(message, std::min<std::size_t>(200, std::max<std::size_t>(16, o.max_message_length)));
    if (!clean.empty()) props.set("message", clean);
    if (!frames.empty()) props.set("top_frame", w::utf8_truncate(frames[0], 160));
    if (!app_version_.empty() && app_version_.size() <= 32) props.set("app_version", app_version_);
    return track("fr_error", props);
  }

  void set_app_version(const std::string& version) { app_version_ = version; }

  // ------------------------------------------------------------ oturum

  // Arka plana geçiş ve dönüş: 30 dakikayı aşan ayrılıktan sonra yeni session_id üretilir.
  void notify_background() {
    if (!last_background_ms_) last_background_ms_ = env_.now_ms();
  }
  void notify_foreground() {
    const std::int64_t now = env_.now_ms();
    if (options_.session_timeout_ms > 0 && last_background_ms_ && now - *last_background_ms_ >= options_.session_timeout_ms) session_id_ = new_ulid();
    last_background_ms_.reset();
  }

  void reset() {
    session_id_ = options_.session_timeout_ms > 0 ? new_ulid() : std::string();
    last_background_ms_.reset();
    anonymous_id_.clear();
    core_.identify("");
    order_.clear();
    if (store_) {
      store_->clear();
      store_->remove_marker(kMarkerInstallId);
    }
    install_id_.clear();
    w::Consent keep = consent_;
    core_.set_consent(w::Consent());  // kuyruğu boşaltır
    core_.set_consent(effective_consent(keep));
  }

  // ------------------------------------------------------------ teslim (kalıcı kuyruk eşlemesi)

  // EventCore::on_response + kalıcı depodan silme. Kabul (202) ve kalıcı ret (4xx, 429 hariç) batch'i siler; 401/403 hepsini.
  w::DeliveryResult deliver_response(const w::Batch& batch, int status, const std::string& body, const std::string& retry_after) {
    const w::DeliveryResult result = core_.on_response(batch, status, body, retry_after, env_.mono_ms());
    if (status == 202 || (status >= 400 && status < 500 && status != 429)) {
      forget(batch);
      if (status == 401 || status == 403) {
        order_.clear();
        if (store_) store_->clear();
      }
    }
    return result;
  }

  w::DeliveryResult deliver_network_error(const w::Batch& batch, const std::string& message) { return core_.on_network_error(batch, message, env_.mono_ms()); }

  // ------------------------------------------------------------ atıf

  void start_attribution(ReferrerReader reader) {
    if (!reader) return;
    if (!store_) {
      warn("atıf: kalıcı depo yok, ilk açılış tekrarlanabileceğinden başlatılmadı");
      return;
    }
    referrer_reader_ = std::move(reader);
    process_attribution();
  }

  void handle_deep_link(const std::string& url) {
    const auto link = parse_deep_link(url);
    if (!link) return;
    const std::int64_t at = env_.now_ms();
    if (!consent_decided_) {
      pending_link_ = link;
      pending_link_at_ = at;
      return;
    }
    if (!consent_.analytics) return;
    emit_deep_link(*link, at);
  }

  // Play Install Referrer'dan gelen ertelenmiş yolu bir kez teslim eder (yalnız fr_click ile gelen uygulama içi yol).
  std::string consume_deferred_deep_link() {
    if (!store_ || !consent_.analytics || !effective_advertising()) return std::string();
    std::string path;
    if (!store_->get_marker(kMarkerDeferredDeepLink, path)) return std::string();
    store_->remove_marker(kMarkerDeferredDeepLink);
    return path;
  }

  // iOS: AdServices token'ını kurulum kimliğiyle sunucuya iletir (ADR-0007). Kesin tekil atıf iddia edilmez.
  void bind_install(TokenReader reader, HttpPost post, std::function<void(const InstallBinding&)> done) {
    if (!done) return;
    if (options_.attribution_api_url.empty() || options_.project_id.empty()) return done(InstallBinding{install_status::not_configured, ""});
    if (!advertising_allowed_now()) return done(InstallBinding{install_status::skipped_no_consent, ""});
    if (!reader || !post) return done(InstallBinding{install_status::unsupported, ""});
    auto answered = std::make_shared<bool>(false);
    reader([this, post, done, answered](const TokenResult& result) {
      if (*answered) return;
      *answered = true;
      complete_bind(result, post, done);
    });
  }

 private:

  std::string new_ulid() {
    std::string id = ulid_.next(env_.now_ms(), env_.fill);
    return id;
  }

  void warn(const std::string& message) {
    if (env_.log) env_.log(message);
  }

  TrackResult reject(const char* name) {
    warn(std::string(name) + ": girdi sözleşmeye uymuyor, olay üretilmedi");
    return TrackResult();
  }

  bool effective_advertising() const {
    if (!consent_.advertising) return false;
    if (!options_.tracking_status) return true;
    const TrackingStatus status = options_.tracking_status();
    return status != TrackingStatus::denied && status != TrackingStatus::restricted;
  }

  w::Consent effective_consent(const w::Consent& base) const {
    w::Consent out = base;
    out.advertising = base.advertising && effective_advertising();
    return out;
  }

  void apply_core_consent() { core_.set_consent(effective_consent(consent_)); }

  bool advertising_allowed_now() const { return consent_.analytics && effective_advertising(); }

  TrackResult track_with_page(const std::string& name, const Value& properties, std::optional<std::int64_t> occurred_ms, const std::string& page_url) {
    TrackResult result;
    w::TrackOptions options;
    options.anonymous_id = anonymous_id_;
    options.session_id = session_id_;
    if (occurred_ms) options.occurred_at_ms = occurred_ms;
    if (!page_url.empty()) {
      w::Context context;
      context.page_url = page_url;
      options.context = context;
    }
    // Eşleştirme kodu yalnız ilk üretilen olaya eklenir; özellik sınırı doluysa sonraki olayı bekler.
    const bool attach_code = !pending_install_code_.empty() &&
                             (properties.is_null() || (properties.is_object() && (properties.size() < w::kMaxProperties || properties.find(kInstallCodeProperty) != nullptr)));
    Value with_code;
    if (attach_code) {
      with_code = properties.is_object() ? properties : Value::make_object();
      with_code.set(kInstallCodeProperty, pending_install_code_);
    }
    const w::TrackOutcome outcome = core_.track(name, attach_code ? with_code : properties, options, env_.now_ms(), env_.fill);
    if (outcome.error.failed()) {
      warn(outcome.error.message);
      return result;
    }
    if (!outcome.produced) return result;
    if (attach_code) pending_install_code_.clear();
    result.produced = true;
    result.queue_full = outcome.queue_full;
    result.event_id = outcome.event_id;
    order_.push_back(outcome.event_id);
    if (store_ && outcome.event_json.size() <= kMaxEventChars) store_->add(crypto::StoredEvent{outcome.event_id, outcome.event_json});
    if (outcome.dropped_now > 0) {
      std::set<std::string> ids;
      for (int i = 0; i < outcome.dropped_now && !order_.empty(); ++i) {
        ids.insert(order_.front());
        order_.pop_front();
      }
      if (store_) store_->remove(ids);
      warn("kuyruk sınırı aşıldı, en eski " + std::to_string(outcome.dropped_now) + " olay atıldı");
    }
    return result;
  }

  void forget(const w::Batch& batch) {
    std::set<std::string> ids;
    for (const w::QueuedEvent& item : batch) ids.insert(item.id);
    order_.erase(std::remove_if(order_.begin(), order_.end(), [&ids](const std::string& id) { return ids.count(id) != 0; }), order_.end());
    if (store_) store_->remove(ids);
  }

  // İzin verilince diskteki olaylar event_id'leri korunarak belleğe alınır (aynı event_id ile tekrar gönderim).
  void load_persisted() {
    if (!store_ || store_loaded_) return;
    store_loaded_ = true;
    std::set<std::string> known(order_.begin(), order_.end());
    std::set<std::string> invalid;
    std::vector<w::QueuedEvent> restored;
    for (const crypto::StoredEvent& row : store_->load()) {
      if (row.payload.size() > kMaxEventChars) {
        invalid.insert(row.id);
      } else if (known.insert(row.id).second) {
        restored.push_back(w::QueuedEvent{row.id, row.payload});
      }
    }
    // Eski olaylar (diskteki) yeni üretilenlerin önüne girer: sıra eskiden yeniye kalır.
    std::deque<std::string> rebuilt;
    for (const w::QueuedEvent& item : restored) rebuilt.push_back(item.id);
    for (const std::string& id : order_) rebuilt.push_back(id);
    order_ = rebuilt;
    for (w::QueuedEvent& item : restored) {
      std::vector<std::string> dropped;
      core_.restore(std::move(item), dropped);
      for (const std::string& id : dropped) {
        invalid.insert(id);
        order_.erase(std::remove(order_.begin(), order_.end(), id), order_.end());
      }
    }
    if (!invalid.empty()) store_->remove(invalid);
  }

  bool admit_error(const std::string& fingerprint) {
    const ErrorOptions& o = options_.errors;
    if (o.max_per_minute <= 0 || o.max_per_fingerprint_per_minute <= 0) return false;
    const std::int64_t now = env_.now_ms();
    prune(error_times_, now);
    if (static_cast<int>(error_times_.size()) >= o.max_per_minute) return false;
    if (error_times_by_fp_.find(fingerprint) == error_times_by_fp_.end() && error_times_by_fp_.size() >= 64) {
      for (auto it = error_times_by_fp_.begin(); it != error_times_by_fp_.end();) {
        prune(it->second, now);
        it = it->second.empty() ? error_times_by_fp_.erase(it) : std::next(it);
      }
      if (error_times_by_fp_.size() >= 64) error_times_by_fp_.clear();
    }
    std::vector<std::int64_t>& per = error_times_by_fp_[fingerprint];
    prune(per, now);
    if (static_cast<int>(per.size()) >= o.max_per_fingerprint_per_minute) return false;
    error_times_.push_back(now);
    per.push_back(now);
    return true;
  }

  static void prune(std::vector<std::int64_t>& times, std::int64_t now) {
    times.erase(std::remove_if(times.begin(), times.end(), [now](std::int64_t t) { return t <= now - 60000; }), times.end());
  }

  // ---- atıf ayrıntıları

  void on_consent_applied() {
    std::optional<DeepLink> pending;
    std::int64_t pending_at = 0;
    const bool analytics = consent_.analytics;
    if (analytics) {
      pending = pending_link_;
      pending_at = pending_link_at_;
    }
    pending_link_.reset();
    if (analytics && !effective_advertising()) {
      // Reklam izni yoksa kanıt, kurulum kimliği ve ertelenmiş yol taşınmaz.
      link_evidence_.reset();
      install_id_.clear();
      if (store_) {
        store_->remove_marker(kMarkerInstallId);
        store_->remove_marker(kMarkerDeferredDeepLink);
      }
    }
    if (!analytics) return;
    if (pending) emit_deep_link(*pending, pending_at);
    process_attribution();
  }

  void emit_deep_link(const DeepLink& link, std::int64_t at) {
    const bool advertising = effective_advertising();
    if (advertising && !link.params.empty()) link_evidence_ = link.params;
    Value props = Value::make_object();
    if (advertising) {
      props.set("attribution_source", "app_link");
      link.params.write_to(props);
    } else {
      // İzin yoksa atıf yoktur: açılış sayılır, kanıt gönderilmez.
      props.set("attribution_source", "none");
    }
    track_with_page("deep_link_opened", props, at, link.clean_url);
  }

  void process_attribution() {
    if (!referrer_reader_ || !store_ || !consent_decided_ || !consent_.analytics) return;
    const bool advertising = effective_advertising();
    std::string first_open;
    std::string checked;
    const bool has_first = store_->get_marker(kMarkerFirstOpen, first_open);
    const bool has_checked = store_->get_marker(kMarkerReferrerChecked, checked);
    bool start_first = false;
    bool start_follow = false;
    if (!has_first) {
      if (first_open_started_) return;
      first_open_started_ = true;
      start_first = true;
    } else if (advertising && !has_checked && !follow_up_started_) {
      follow_up_started_ = true;
      start_follow = true;
    }
    if (start_first) {
      const std::int64_t at = env_.now_ms();
      if (advertising) {
        read_referrer([this, at](bool has, const std::string& raw) { complete_first_open(at, has ? &raw : nullptr); });
      } else {
        complete_first_open(at, nullptr);
      }
    } else if (start_follow) {
      read_referrer([this](bool has, const std::string& raw) { complete_follow_up(has ? &raw : nullptr); });
    }
  }

  void read_referrer(std::function<void(bool, const std::string&)> on_result) {
    auto settled = std::make_shared<bool>(false);
    referrer_reader_([settled, on_result](bool has, const std::string& raw) {
      if (*settled) return;
      *settled = true;
      on_result(has, raw);
    });
  }

  void complete_first_open(std::int64_t at, const std::string* raw) {
    if (!consent_.analytics) {
      // İzin okuma sırasında geri çekildi: işaret yazılmadı, sonraki onayda yeniden denenir.
      first_open_started_ = false;
      return;
    }
    const bool advertising = effective_advertising();
    std::optional<AttributionParams> referrer;
    if (advertising && raw != nullptr) referrer = parse_attribution_query(*raw);
    Value props = Value::make_object();
    if (advertising && referrer && !referrer->empty() && !referrer->play_organic_default()) {
      props.set("attribution_source", "play_install_referrer");
      referrer->write_to(props);
    } else if (advertising && link_evidence_) {
      props.set("attribution_source", "app_link");
      link_evidence_->write_to(props);
    } else {
      props.set("attribution_source", "none");
    }
    const TrackResult tracked = track_with_page("app_first_open", props, at, std::string());
    if (!tracked.produced) {
      first_open_started_ = false;
      return;
    }
    store_->put_marker(kMarkerFirstOpen, tracked.event_id);
    // Sonradan gelen izinde bakış penceresi gerçek ilk açılışa göre işlesin.
    store_->put_marker(kMarkerFirstOpenAt, std::to_string(at));
    if (advertising) {
      store_->put_marker(kMarkerReferrerChecked, "1");
      if (referrer && !referrer->deep_link_path.empty()) store_->put_marker(kMarkerDeferredDeepLink, referrer->deep_link_path);
    }
  }

  void complete_follow_up(const std::string* raw) {
    follow_up_started_ = false;
    if (!consent_.analytics || !effective_advertising()) return;
    const AttributionParams referrer = raw == nullptr ? AttributionParams() : parse_attribution_query(*raw);
    if (referrer.empty() || referrer.play_organic_default()) {
      store_->put_marker(kMarkerReferrerChecked, "1");
      return;
    }
    Value props = Value::make_object();
    props.set("attribution_source", "play_install_referrer");
    props.set("consent_followup", true);
    std::string first_open_at;
    if (store_->get_marker(kMarkerFirstOpenAt, first_open_at) && !first_open_at.empty() &&
        std::all_of(first_open_at.begin(), first_open_at.end(), [](char c) { return c >= '0' && c <= '9'; })) {
      props.set("first_open_at", w::format_time(std::stoll(first_open_at)));
    }
    referrer.write_to(props);
    const TrackResult tracked = track_with_page("deep_link_opened", props, std::nullopt, std::string());
    if (!tracked.produced) return;
    store_->put_marker(kMarkerReferrerChecked, "1");
    if (!referrer.deep_link_path.empty()) store_->put_marker(kMarkerDeferredDeepLink, referrer.deep_link_path);
  }

  std::string ensure_install_id() {
    if (!install_id_.empty()) return install_id_;
    std::string stored;
    if (store_ && store_->get_marker(kMarkerInstallId, stored) && stored.size() == 26) install_id_ = stored;
    else install_id_ = new_ulid();
    if (store_) store_->put_marker(kMarkerInstallId, install_id_);
    return install_id_;
  }

  void complete_bind(const TokenResult& result, const HttpPost& post, const std::function<void(const InstallBinding&)>& done) {
    // Sonuç, gönderim sırasında izin geri çekildiyse kimlik içermez.
    const auto finish = [this, done](const char* status) { done(InstallBinding{status, advertising_allowed_now() ? ensure_install_id() : std::string()}); };
    if (!advertising_allowed_now()) return done(InstallBinding{install_status::skipped_no_consent, ""});
    if (result.status == "failed" || result.status.empty()) return finish(install_status::token_unavailable);
    if (result.status == "unsupported") return finish(install_status::unsupported);
    const std::string install_id = ensure_install_id();
    std::string body = "{\"token\":";
    w::append_json_string(body, result.token);
    body += ",\"install_id\":\"" + install_id + "\"}";
    std::string root = options_.attribution_api_url;
    while (!root.empty() && root.back() == '/') root.pop_back();
    const std::string url = root + "/v1/projects/" + options_.project_id + "/attribution/apple-adservices/tokens";
    const w::Headers headers = {{"Content-Type", "application/json"},
                                {"Accept", "application/json, application/problem+json"},
                                {"Authorization", "Bearer " + options_.project_key},
                                {"User-Agent", options_.sdk.name + "/" + options_.sdk.version}};
    auto responded = std::make_shared<bool>(false);
    post(url, headers, body, [this, finish, responded](int status) {
      if (*responded) return;
      *responded = true;
      if (status == 202) return finish(install_status::received);
      if (status == 0 || status == 429 || status >= 500) return finish(install_status::temporary_failure);
      warn("AdServices token reddedildi: HTTP " + std::to_string(status));
      finish(install_status::rejected);
    });
  }

  Options options_;
  Environment env_;
  std::unique_ptr<crypto::EventStore> store_;
  w::EventCore core_;
  w::UlidGenerator ulid_;
  w::Consent consent_;
  bool consent_decided_ = false;
  bool store_loaded_ = false;
  std::deque<std::string> order_;
  std::string session_id_;
  std::string anonymous_id_;
  std::string app_version_;
  std::optional<std::int64_t> last_background_ms_;
  std::vector<std::int64_t> error_times_;
  std::map<std::string, std::vector<std::int64_t>> error_times_by_fp_;
  std::int64_t errors_suppressed_ = 0;
  ReferrerReader referrer_reader_;
  bool first_open_started_ = false;
  bool follow_up_started_ = false;
  std::optional<DeepLink> pending_link_;
  std::int64_t pending_link_at_ = 0;
  std::optional<AttributionParams> link_evidence_;
  std::string install_id_;
  std::string pending_install_code_;
};

}  // namespace game
}  // namespace feralin

#endif  // FERALIN_GAME_HPP
