// Feralin UTP v1 tel biçimi ve teslim durum makinesi: JSON yazıcı/okuyucu, doğrulama, ULID, Idempotency-Key, kuyruk.
//
// Bu dosya motor ve ağdan bağımsızdır; yalnız C++17 standart kütüphanesi kullanır, exception ve RTTI gerektirmez.
// Birebir kopyası sdks/unreal/Feralin/Source/Feralin/Private/FeralinWire.hpp içindedir (Unreal eklentisi tek başına
// dağıtıldığı için dışarıdan dosya alamaz). Burada yapılan değişiklik oraya kopyalanmalıdır:
// sdks/unreal/tests/run.mjs iki dosyanın aynı olduğunu denetler.
//
// Eş zamanlılık: EventCore iş parçacığı güvenli değildir; kilidi veya tek iş parçacığı kuralını çağıran sağlar.
#ifndef FERALIN_WIRE_HPP
#define FERALIN_WIRE_HPP

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <initializer_list>
#include <iomanip>
#include <limits>
#include <locale>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

namespace feralin {
namespace wire {

constexpr int kMaxBatchSize = 500;
constexpr int kDefaultBatchSize = 100;
constexpr int kDefaultQueueLimit = 1000;
constexpr int kDefaultFlushIntervalMs = 2000;
constexpr int kDefaultTimeoutMs = 10000;
constexpr int kCloseTimeoutMs = 5000;
constexpr std::size_t kMaxResponseBody = 64 * 1024;
constexpr std::size_t kMaxEventNameLength = 100;
constexpr std::size_t kMaxProperties = 100;
constexpr std::size_t kMaxIdentifierLength = 128;
constexpr int kMaxJsonDepth = 32;
constexpr std::int64_t kMinBackoffMs = 1000;
constexpr std::int64_t kMaxBackoffMs = 30000;
constexpr std::int64_t kMaxTimestampMs = 253402300799999;  // 9999-12-31T23:59:59.999Z
constexpr int kSchemaVersion = 1;

inline const char* attribution_click_property() { return "fr_click"; }

enum class ErrorCode {
  none,
  configuration,  // geçersiz proje anahtarı, adres veya seçenek
  invalid_event,  // ad, özellik veya kimlik alanı UTP v1 kurallarına uymuyor
  client_closed,  // close() sonrası çağrı
  rejected,       // 4xx (429 hariç): olaylar kalıcı olarak atıldı
  temporary       // 5xx, 429 veya ağ hatası: olaylar kuyrukta, aynı anahtarla yeniden denenecek
};

struct Error {
  ErrorCode code = ErrorCode::none;
  int status = 0;
  std::string message;

  bool failed() const { return code != ErrorCode::none; }
};

inline Error make_error(ErrorCode code, std::string message, int status = 0) {
  Error out;
  out.code = code;
  out.status = status;
  out.message = std::move(message);
  return out;
}

// İzin anlık görüntüsü. analytics false ise hiçbir olay üretilmez.
struct Consent {
  bool analytics = false;
  bool advertising = false;
  bool personalization = false;
  bool session_replay = false;
};

// ------------------------------------------------------------------ UTF-8

// i konumundaki kod noktasını doğrular ve ilerletir. Uzun kodlama, vekil çift ve U+10FFFF üstü reddedilir.
inline bool utf8_step(const std::string& text, std::size_t& i) {
  const auto byte_at = [&text](std::size_t at) { return static_cast<unsigned char>(text[at]); };
  const unsigned char lead = byte_at(i);
  std::size_t extra = 0;
  std::uint32_t point = 0;
  if (lead < 0x80) {
    i += 1;
    return true;
  }
  if (lead >= 0xC2 && lead <= 0xDF) {
    extra = 1;
    point = lead & 0x1Fu;
  } else if (lead >= 0xE0 && lead <= 0xEF) {
    extra = 2;
    point = lead & 0x0Fu;
  } else if (lead >= 0xF0 && lead <= 0xF4) {
    extra = 3;
    point = lead & 0x07u;
  } else {
    return false;
  }
  if (i + extra >= text.size()) return false;
  for (std::size_t k = 1; k <= extra; ++k) {
    const unsigned char next = byte_at(i + k);
    if ((next & 0xC0u) != 0x80u) return false;
    point = (point << 6) | (next & 0x3Fu);
  }
  if (extra == 2 && point < 0x800u) return false;
  if (extra == 3 && point < 0x10000u) return false;
  if (point >= 0xD800u && point <= 0xDFFFu) return false;
  if (point > 0x10FFFFu) return false;
  i += extra + 1;
  return true;
}

inline bool utf8_valid(const std::string& text) {
  for (std::size_t i = 0; i < text.size();) {
    if (!utf8_step(text, i)) return false;
  }
  return true;
}

// Kod noktası sayısı; JSON Schema maxLength böyle sayar. Geçersiz UTF-8 için false.
inline bool utf8_length(const std::string& text, std::size_t& length) {
  length = 0;
  for (std::size_t i = 0; i < text.size(); ++length) {
    if (!utf8_step(text, i)) return false;
  }
  return true;
}

// En fazla limit kod noktası; çok baytlı karakter ortadan kesilmez. Girdi geçerli UTF-8 değilse boş döner.
inline std::string utf8_truncate(const std::string& text, std::size_t limit) {
  std::size_t i = 0;
  for (std::size_t count = 0; i < text.size() && count < limit; ++count) {
    if (!utf8_step(text, i)) return std::string();
  }
  return text.substr(0, i);
}

// ------------------------------------------------------------------ JSON değeri

class Value {
 public:
  enum class Type { null, boolean, integer, real, string, array, object };

  Value() = default;
  Value(std::nullptr_t) {}
  Value(bool flag) : type_(Type::boolean), bool_(flag) {}
  Value(double number) : type_(Type::real), real_(number) {}
  Value(float number) : type_(Type::real), real_(static_cast<double>(number)) {}
  Value(const char* text) : type_(Type::string), text_(text != nullptr ? text : "") {}
  Value(std::string text) : type_(Type::string), text_(std::move(text)) {}

  template <typename T, typename std::enable_if<std::is_integral<T>::value && !std::is_same<T, bool>::value, int>::type = 0>
  Value(T number) {
    // int64 aralığına sığmayan işaretsiz değer kesirli sayı olarak gider; sessizce negatife dönmez.
    if (std::is_unsigned<T>::value &&
        static_cast<unsigned long long>(number) > static_cast<unsigned long long>(std::numeric_limits<std::int64_t>::max())) {
      type_ = Type::real;
      real_ = static_cast<double>(number);
    } else {
      type_ = Type::integer;
      int_ = static_cast<std::int64_t>(number);
    }
  }

  static Value make_array() {
    Value out;
    out.type_ = Type::array;
    return out;
  }

  static Value make_object() {
    Value out;
    out.type_ = Type::object;
    return out;
  }

  Type type() const { return type_; }
  bool is_null() const { return type_ == Type::null; }
  bool is_object() const { return type_ == Type::object; }
  bool is_array() const { return type_ == Type::array; }
  bool is_string() const { return type_ == Type::string; }
  bool is_integer() const { return type_ == Type::integer; }

  bool as_bool() const { return bool_; }
  std::int64_t as_int() const { return type_ == Type::real ? static_cast<std::int64_t>(real_) : int_; }
  double as_double() const { return type_ == Type::integer ? static_cast<double>(int_) : real_; }
  const std::string& as_string() const { return text_; }

  std::size_t size() const { return items_.size(); }
  const Value& at(std::size_t index) const { return items_[index]; }
  const std::string& key_at(std::size_t index) const { return keys_[index]; }

  void push(Value item) { items_.push_back(std::move(item)); }

  // Aynı anahtar yeniden verilirse son değer geçerlidir (sözlük anlamı).
  void set(const std::string& key, Value item) {
    for (std::size_t i = 0; i < keys_.size(); ++i) {
      if (keys_[i] == key) {
        items_[i] = std::move(item);
        return;
      }
    }
    keys_.push_back(key);
    items_.push_back(std::move(item));
  }

  const Value* find(const std::string& key) const {
    for (std::size_t i = 0; i < keys_.size(); ++i) {
      if (keys_[i] == key) return &items_[i];
    }
    return nullptr;
  }

  void erase(const std::string& key) {
    for (std::size_t i = 0; i < keys_.size(); ++i) {
      if (keys_[i] == key) {
        keys_.erase(keys_.begin() + static_cast<std::ptrdiff_t>(i));
        items_.erase(items_.begin() + static_cast<std::ptrdiff_t>(i));
        return;
      }
    }
  }

 private:
  Type type_ = Type::null;
  bool bool_ = false;
  std::int64_t int_ = 0;
  double real_ = 0.0;
  std::string text_;
  std::vector<std::string> keys_;
  std::vector<Value> items_;
};

using Properties = std::vector<std::pair<std::string, Value>>;

inline Value properties_to_value(const Properties& properties) {
  if (properties.empty()) return Value();
  Value out = Value::make_object();
  for (const auto& item : properties) out.set(item.first, item.second);
  return out;
}

// ------------------------------------------------------------------ JSON yazıcı

// Metin geçerli UTF-8 değilse veya NUL içeriyorsa false: böyle bir olay batch'i zehirlemeden önce reddedilir.
inline bool append_json_string(std::string& out, const std::string& text) {
  if (text.find('\0') != std::string::npos || !utf8_valid(text)) return false;
  static const char kHex[] = "0123456789abcdef";
  out.push_back('"');
  for (const char c : text) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\b': out += "\\b"; break;
      case '\f': out += "\\f"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default: {
        const unsigned char u = static_cast<unsigned char>(c);
        if (u < 0x20) {
          out += "\\u00";
          out.push_back(kHex[u >> 4]);
          out.push_back(kHex[u & 0x0Fu]);
        } else {
          out.push_back(c);
        }
      }
    }
  }
  out.push_back('"');
  return true;
}

// Geri okunduğunda aynı sayıyı veren en kısa gösterim; yerel ayar ondalık ayırıcıyı değiştiremez. NaN ve sonsuz reddedilir.
inline bool append_json_double(std::string& out, double number) {
  if (!std::isfinite(number)) return false;
  for (int precision = 15; precision <= 17; ++precision) {
    std::ostringstream writer;
    writer.imbue(std::locale::classic());
    writer << std::setprecision(precision) << number;
    const std::string text = writer.str();
    std::istringstream reader(text);
    reader.imbue(std::locale::classic());
    double parsed = 0.0;
    reader >> parsed;
    // Yuvarlanan metin taşabilir (DBL_MAX): okuma hatası da eşleşme sayılmaz.
    if (precision == 17 || (!reader.fail() && parsed == number)) {
      out += text;
      return true;
    }
  }
  return false;
}

inline bool append_json(std::string& out, const Value& value, int depth = 0) {
  if (depth > kMaxJsonDepth) return false;
  switch (value.type()) {
    case Value::Type::null:
      out += "null";
      return true;
    case Value::Type::boolean:
      out += value.as_bool() ? "true" : "false";
      return true;
    case Value::Type::integer:
      out += std::to_string(value.as_int());
      return true;
    case Value::Type::real:
      return append_json_double(out, value.as_double());
    case Value::Type::string:
      return append_json_string(out, value.as_string());
    case Value::Type::array: {
      out.push_back('[');
      for (std::size_t i = 0; i < value.size(); ++i) {
        if (i != 0) out.push_back(',');
        if (!append_json(out, value.at(i), depth + 1)) return false;
      }
      out.push_back(']');
      return true;
    }
    case Value::Type::object: {
      out.push_back('{');
      for (std::size_t i = 0; i < value.size(); ++i) {
        if (i != 0) out.push_back(',');
        if (!append_json_string(out, value.key_at(i))) return false;
        out.push_back(':');
        if (!append_json(out, value.at(i), depth + 1)) return false;
      }
      out.push_back('}');
      return true;
    }
  }
  return false;
}

// ------------------------------------------------------------------ JSON okuyucu

class JsonReader {
 public:
  explicit JsonReader(const std::string& text) : text_(text) {}

  bool parse(Value& out) {
    skip_space();
    if (!parse_value(out, 0)) return false;
    skip_space();
    return pos_ == text_.size();
  }

 private:
  void skip_space() {
    while (pos_ < text_.size()) {
      const char c = text_[pos_];
      if (c != ' ' && c != '\t' && c != '\n' && c != '\r') return;
      ++pos_;
    }
  }

  bool consume(const char* literal) {
    const std::string word(literal);
    if (text_.compare(pos_, word.size(), word) != 0) return false;
    pos_ += word.size();
    return true;
  }

  bool parse_value(Value& out, int depth) {
    if (depth > kMaxJsonDepth || pos_ >= text_.size()) return false;
    const char c = text_[pos_];
    if (c == '{') return parse_object(out, depth);
    if (c == '[') return parse_array(out, depth);
    if (c == '"') {
      std::string text;
      if (!parse_string(text)) return false;
      out = Value(std::move(text));
      return true;
    }
    if (c == 't') {
      out = Value(true);
      return consume("true");
    }
    if (c == 'f') {
      out = Value(false);
      return consume("false");
    }
    if (c == 'n') {
      out = Value();
      return consume("null");
    }
    return parse_number(out);
  }

  bool parse_object(Value& out, int depth) {
    out = Value::make_object();
    ++pos_;
    skip_space();
    if (pos_ < text_.size() && text_[pos_] == '}') {
      ++pos_;
      return true;
    }
    for (;;) {
      skip_space();
      if (pos_ >= text_.size() || text_[pos_] != '"') return false;
      std::string key;
      if (!parse_string(key)) return false;
      skip_space();
      if (pos_ >= text_.size() || text_[pos_] != ':') return false;
      ++pos_;
      skip_space();
      Value item;
      if (!parse_value(item, depth + 1)) return false;
      out.set(key, std::move(item));
      skip_space();
      if (pos_ >= text_.size()) return false;
      if (text_[pos_] == ',') {
        ++pos_;
        continue;
      }
      if (text_[pos_] == '}') {
        ++pos_;
        return true;
      }
      return false;
    }
  }

  bool parse_array(Value& out, int depth) {
    out = Value::make_array();
    ++pos_;
    skip_space();
    if (pos_ < text_.size() && text_[pos_] == ']') {
      ++pos_;
      return true;
    }
    for (;;) {
      skip_space();
      Value item;
      if (!parse_value(item, depth + 1)) return false;
      out.push(std::move(item));
      skip_space();
      if (pos_ >= text_.size()) return false;
      if (text_[pos_] == ',') {
        ++pos_;
        continue;
      }
      if (text_[pos_] == ']') {
        ++pos_;
        return true;
      }
      return false;
    }
  }

  bool parse_hex4(std::uint32_t& point) {
    if (pos_ + 4 > text_.size()) return false;
    point = 0;
    for (int i = 0; i < 4; ++i) {
      const char c = text_[pos_++];
      std::uint32_t digit = 0;
      if (c >= '0' && c <= '9') {
        digit = static_cast<std::uint32_t>(c - '0');
      } else if (c >= 'a' && c <= 'f') {
        digit = static_cast<std::uint32_t>(c - 'a') + 10u;
      } else if (c >= 'A' && c <= 'F') {
        digit = static_cast<std::uint32_t>(c - 'A') + 10u;
      } else {
        return false;
      }
      point = (point << 4) | digit;
    }
    return true;
  }

  static void append_utf8(std::string& out, std::uint32_t point) {
    if (point < 0x80u) {
      out.push_back(static_cast<char>(point));
    } else if (point < 0x800u) {
      out.push_back(static_cast<char>(0xC0u | (point >> 6)));
      out.push_back(static_cast<char>(0x80u | (point & 0x3Fu)));
    } else if (point < 0x10000u) {
      out.push_back(static_cast<char>(0xE0u | (point >> 12)));
      out.push_back(static_cast<char>(0x80u | ((point >> 6) & 0x3Fu)));
      out.push_back(static_cast<char>(0x80u | (point & 0x3Fu)));
    } else {
      out.push_back(static_cast<char>(0xF0u | (point >> 18)));
      out.push_back(static_cast<char>(0x80u | ((point >> 12) & 0x3Fu)));
      out.push_back(static_cast<char>(0x80u | ((point >> 6) & 0x3Fu)));
      out.push_back(static_cast<char>(0x80u | (point & 0x3Fu)));
    }
  }

  bool parse_string(std::string& out) {
    ++pos_;  // açılış tırnağı
    while (pos_ < text_.size()) {
      const char c = text_[pos_++];
      if (c == '"') return utf8_valid(out);
      if (static_cast<unsigned char>(c) < 0x20) return false;
      if (c != '\\') {
        out.push_back(c);
        continue;
      }
      if (pos_ >= text_.size()) return false;
      const char escape = text_[pos_++];
      switch (escape) {
        case '"': out.push_back('"'); break;
        case '\\': out.push_back('\\'); break;
        case '/': out.push_back('/'); break;
        case 'b': out.push_back('\b'); break;
        case 'f': out.push_back('\f'); break;
        case 'n': out.push_back('\n'); break;
        case 'r': out.push_back('\r'); break;
        case 't': out.push_back('\t'); break;
        case 'u': {
          std::uint32_t point = 0;
          if (!parse_hex4(point)) return false;
          if (point >= 0xDC00u && point <= 0xDFFFu) return false;
          if (point >= 0xD800u && point <= 0xDBFFu) {
            if (pos_ + 2 > text_.size() || text_[pos_] != '\\' || text_[pos_ + 1] != 'u') return false;
            pos_ += 2;
            std::uint32_t low = 0;
            if (!parse_hex4(low) || low < 0xDC00u || low > 0xDFFFu) return false;
            point = 0x10000u + ((point - 0xD800u) << 10) + (low - 0xDC00u);
          }
          append_utf8(out, point);
          break;
        }
        default:
          return false;
      }
    }
    return false;
  }

  bool at_digit() const { return pos_ < text_.size() && text_[pos_] >= '0' && text_[pos_] <= '9'; }

  bool parse_number(Value& out) {
    const std::size_t start = pos_;
    bool negative = false;
    if (pos_ < text_.size() && text_[pos_] == '-') {
      negative = true;
      ++pos_;
    }
    if (!at_digit()) return false;
    if (text_[pos_] == '0') {
      ++pos_;
      if (at_digit()) return false;
    } else {
      while (at_digit()) ++pos_;
    }
    bool integral = true;
    if (pos_ < text_.size() && text_[pos_] == '.') {
      integral = false;
      ++pos_;
      if (!at_digit()) return false;
      while (at_digit()) ++pos_;
    }
    if (pos_ < text_.size() && (text_[pos_] == 'e' || text_[pos_] == 'E')) {
      integral = false;
      ++pos_;
      if (pos_ < text_.size() && (text_[pos_] == '+' || text_[pos_] == '-')) ++pos_;
      if (!at_digit()) return false;
      while (at_digit()) ++pos_;
    }
    const std::string token = text_.substr(start, pos_ - start);
    if (integral) {
      // Taşma olmazsa tam sayı olarak kalır; aksi halde kesirli sayıya düşer.
      std::uint64_t magnitude = 0;
      bool overflow = false;
      const std::uint64_t limit = negative ? static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max()) + 1u
                                           : static_cast<std::uint64_t>(std::numeric_limits<std::int64_t>::max());
      for (std::size_t i = negative ? 1u : 0u; i < token.size(); ++i) {
        const std::uint64_t digit = static_cast<std::uint64_t>(token[i] - '0');
        if (magnitude > (limit - digit) / 10u) {
          overflow = true;
          break;
        }
        magnitude = magnitude * 10u + digit;
      }
      if (!overflow) {
        if (negative) {
          out = Value(magnitude == limit ? std::numeric_limits<std::int64_t>::min() : -static_cast<std::int64_t>(magnitude));
        } else {
          out = Value(static_cast<std::int64_t>(magnitude));
        }
        return true;
      }
    }
    std::istringstream reader(token);
    reader.imbue(std::locale::classic());
    double parsed = 0.0;
    reader >> parsed;
    if (reader.fail() || !std::isfinite(parsed)) return false;
    out = Value(parsed);
    return true;
  }

  const std::string& text_;
  std::size_t pos_ = 0;
};

inline bool parse_json(const std::string& text, Value& out) {
  JsonReader reader(text);
  return reader.parse(out);
}

// ------------------------------------------------------------------ doğrulama

inline bool ascii_lower(char c) { return c >= 'a' && c <= 'z'; }
inline bool ascii_alpha(char c) { return ascii_lower(c) || (c >= 'A' && c <= 'Z'); }
inline bool ascii_digit(char c) { return c >= '0' && c <= '9'; }

inline bool valid_event_name(const std::string& name) {
  if (name.empty() || name.size() > kMaxEventNameLength || !ascii_lower(name[0])) return false;
  return std::all_of(name.begin(), name.end(), [](char c) { return ascii_lower(c) || ascii_digit(c) || c == '_'; });
}

inline bool valid_property_key(const std::string& key) {
  if (key.empty() || key.size() > 64 || !ascii_alpha(key[0])) return false;
  return std::all_of(key.begin(), key.end(), [](char c) { return ascii_alpha(c) || ascii_digit(c) || c == '_'; });
}

// Boş değer "yok" demektir. maxLength kod noktası sayar.
inline Error validate_text(const std::string& value, std::size_t max_length, const char* field) {
  std::size_t length = 0;
  if (value.find('\0') != std::string::npos || !utf8_length(value, length)) {
    return make_error(ErrorCode::invalid_event, std::string(field) + " geçerli UTF-8 metin olmalı");
  }
  if (length > max_length) {
    return make_error(ErrorCode::invalid_event, std::string(field) + " en fazla " + std::to_string(max_length) + " karakter olmalı");
  }
  return Error();
}

inline std::string trim(const std::string& text) {
  const char* const spaces = " \t\r\n";
  const std::size_t first = text.find_first_not_of(spaces);
  if (first == std::string::npos) return std::string();
  return text.substr(first, text.find_last_not_of(spaces) - first + 1);
}

// Yalnız public proje anahtarı (pk_) kabul edilir. Anahtar hata metnine asla yazılmaz.
inline Error normalize_project_key(const std::string& raw, std::string& key) {
  key = trim(raw);
  if (key.rfind("sk_", 0) == 0) {
    return make_error(ErrorCode::configuration, "gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin");
  }
  if (key.rfind("pk_", 0) != 0 || key.size() < 8) {
    return make_error(ErrorCode::configuration, "proje anahtarı pk_ ile başlamalı");
  }
  // Başlığa yazılacağı için satır sonu ve denetim karakteri taşıyamaz.
  for (const char c : key) {
    const unsigned char u = static_cast<unsigned char>(c);
    if (u <= 0x20 || u >= 0x7F) return make_error(ErrorCode::configuration, "proje anahtarı yazdırılabilir ASCII olmalı");
  }
  return Error();
}

// http(s) mutlak kök adresini {kök}/v1/batch uç noktasına çevirir.
inline Error collect_endpoint(const std::string& raw, std::string& endpoint) {
  std::string url = trim(raw);
  const std::size_t scheme_end = url.find("://");
  std::string scheme = scheme_end == std::string::npos ? std::string() : url.substr(0, scheme_end);
  std::transform(scheme.begin(), scheme.end(), scheme.begin(), [](char c) { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c - 'A' + 'a') : c; });
  const std::size_t authority = scheme_end == std::string::npos ? 0 : scheme_end + 3;
  if ((scheme != "http" && scheme != "https") || authority >= url.size() || url[authority] == '/') {
    return make_error(ErrorCode::configuration, "collect_url http veya https şemalı mutlak adres olmalı");
  }
  for (const char c : url) {
    const unsigned char u = static_cast<unsigned char>(c);
    if (u <= 0x20 || u >= 0x7F) return make_error(ErrorCode::configuration, "collect_url boşluk veya denetim karakteri içeremez");
  }
  while (!url.empty() && url.back() == '/') url.pop_back();
  endpoint = url + "/v1/batch";
  return Error();
}

// ------------------------------------------------------------------ zaman, ULID, Idempotency-Key

inline void append_padded(std::string& out, std::int64_t number, int width) {
  const std::string digits = std::to_string(number);
  for (int i = static_cast<int>(digits.size()); i < width; ++i) out.push_back('0');
  out += digits;
}

// UTC RFC3339, milisaniye hassasiyeti (ör. 2026-11-03T10:00:00.123Z).
inline std::string format_time(std::int64_t epoch_ms) {
  const std::int64_t day_ms = 86400000;
  std::int64_t days = epoch_ms / day_ms;
  std::int64_t rest = epoch_ms % day_ms;
  if (rest < 0) {
    rest += day_ms;
    days -= 1;
  }
  // Takvim dönüşümü: Howard Hinnant civil_from_days.
  const std::int64_t shifted = days + 719468;
  const std::int64_t era = (shifted >= 0 ? shifted : shifted - 146096) / 146097;
  const std::int64_t day_of_era = shifted - era * 146097;
  const std::int64_t year_of_era = (day_of_era - day_of_era / 1460 + day_of_era / 36524 - day_of_era / 146096) / 365;
  const std::int64_t day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
  const std::int64_t month_index = (5 * day_of_year + 2) / 153;
  const std::int64_t day = day_of_year - (153 * month_index + 2) / 5 + 1;
  const std::int64_t month = month_index < 10 ? month_index + 3 : month_index - 9;
  const std::int64_t year = year_of_era + era * 400 + (month <= 2 ? 1 : 0);

  std::string out;
  out.reserve(24);
  append_padded(out, year, 4);
  out.push_back('-');
  append_padded(out, month, 2);
  out.push_back('-');
  append_padded(out, day, 2);
  out.push_back('T');
  append_padded(out, rest / 3600000, 2);
  out.push_back(':');
  append_padded(out, (rest / 60000) % 60, 2);
  out.push_back(':');
  append_padded(out, (rest / 1000) % 60, 2);
  out.push_back('.');
  append_padded(out, rest % 1000, 3);
  out.push_back('Z');
  return out;
}

using RandomFill = std::function<void(unsigned char*, std::size_t)>;

// Monotonik ULID (26 karakter Crockford base32): 10 karakter zaman (ms) + 16 adet 5 bitlik rastgele basamak.
// Aynı milisaniyede veya saat geri gittiğinde son değer artırılarak sıralama korunur.
class UlidGenerator {
 public:
  std::string next(std::int64_t now_ms, const RandomFill& fill) {
    std::int64_t ms = now_ms;
    if (ms > last_ms_) {
      refill(fill);
    } else {
      ms = last_ms_;
      if (!increment()) {
        ms += 1;
        refill(fill);
      }
    }
    last_ms_ = ms;
    static const char kAlphabet[] = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    std::string out(26, '0');
    std::uint64_t remaining = static_cast<std::uint64_t>(ms);
    for (int i = 9; i >= 0; --i) {
      out[static_cast<std::size_t>(i)] = kAlphabet[remaining & 31u];
      remaining >>= 5;
    }
    for (std::size_t i = 0; i < random_.size(); ++i) out[10 + i] = kAlphabet[random_[i]];
    return out;
  }

 private:
  void refill(const RandomFill& fill) {
    fill(random_.data(), random_.size());
    for (unsigned char& digit : random_) digit = static_cast<unsigned char>(digit & 31u);
  }

  bool increment() {
    for (std::size_t i = random_.size(); i > 0; --i) {
      if (random_[i - 1] < 31u) {
        random_[i - 1] = static_cast<unsigned char>(random_[i - 1] + 1u);
        return true;
      }
      random_[i - 1] = 0;
    }
    return false;
  }

  std::int64_t last_ms_ = -1;
  std::array<unsigned char, 16> random_{};
};

inline bool is_ulid(const std::string& value) {
  static const std::string kAlphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
  if (value.size() != 26 || value[0] > '7') return false;
  return value.find_first_not_of(kAlphabet) == std::string::npos;
}

// Bütün SDK'larla aynı anahtar: sıralı tüm event_id'lerin FNV-1a 64 özeti ve sayı.
inline std::string idempotency_key_for(std::vector<std::string> event_ids) {
  std::sort(event_ids.begin(), event_ids.end());
  std::uint64_t hash = 0xCBF29CE484222325ull;
  const auto mix = [&hash](unsigned char byte) {
    hash ^= byte;
    hash *= 0x100000001B3ull;
  };
  for (std::size_t i = 0; i < event_ids.size(); ++i) {
    if (i != 0) mix(static_cast<unsigned char>(','));
    for (const char c : event_ids[i]) mix(static_cast<unsigned char>(c));
  }
  static const char kHex[] = "0123456789abcdef";
  std::string out(16, '0');
  for (std::size_t i = 16; i > 0; --i) {
    out[i - 1] = kHex[hash & 0x0Fu];
    hash >>= 4;
  }
  return out + "-" + std::to_string(event_ids.size());
}

// ------------------------------------------------------------------ olay biçimi

// Şemadaki context nesnesi; yalnız dolu alanlar gönderilir.
struct Context {
  std::string page_url;
  std::string page_title;
  std::string referrer;
  std::string locale;
  std::string timezone;
  std::optional<std::pair<int, int>> screen;  // genişlik, yükseklik
  std::string app_version;
  std::string app_build;
};

struct TrackOptions {
  std::string user_id;
  std::string anonymous_id;
  std::string session_id;
  std::optional<std::int64_t> occurred_at_ms;
  std::optional<Context> context;
};

struct SdkIdentity {
  std::string name;
  std::string version;
  std::string platform;
};

struct TrackOutcome {
  Error error;
  bool produced = false;  // izin yoksa false: olay üretilmedi, hata da yok
  bool queue_full = false;  // kuyruk batch boyutuna ulaştı: gönderici uyandırılmalı
  int dropped_now = 0;      // kuyruk sınırı yüzünden atılan en eski olay sayısı
  std::string event_id;
  std::string event_json;
};

struct QueuedEvent {
  std::string id;
  std::string json;
};

using Batch = std::vector<QueuedEvent>;

struct DeliveryResult {
  int sent = 0;
  int accepted = 0;
  int rejected = 0;
  std::string batch_id;
  int status = 0;
  int retained = 0;
  Error error;

  bool ok() const { return !error.failed(); }
};

using Headers = std::vector<std::pair<std::string, std::string>>;

inline Headers request_headers(const std::string& project_key, const std::string& idempotency_key, const SdkIdentity& identity) {
  return Headers{
      {"Content-Type", "application/json"},
      {"Accept", "application/json, application/problem+json"},
      {"X-Feralin-Project-Key", project_key},
      {"Idempotency-Key", idempotency_key},
      {"User-Agent", identity.name + "/" + identity.version},
  };
}

inline void append_consent(std::string& out, const Consent& consent) {
  out += "{\"analytics\":";
  out += consent.analytics ? "true" : "false";
  out += ",\"advertising\":";
  out += consent.advertising ? "true" : "false";
  out += ",\"personalization\":";
  out += consent.personalization ? "true" : "false";
  out += ",\"session_replay\":";
  out += consent.session_replay ? "true" : "false";
  out.push_back('}');
}

inline bool append_field(std::string& out, bool& first, const char* name, const std::string& value) {
  if (value.empty()) return true;
  if (!first) out.push_back(',');
  first = false;
  out.push_back('"');
  out += name;
  out += "\":";
  return append_json_string(out, value);
}

inline Error validate_context(const Context& context) {
  struct Limit {
    const std::string* value;
    std::size_t max_length;
    const char* field;
  };
  const Limit limits[] = {
      {&context.page_url, 2048, "context.page_url"}, {&context.page_title, 512, "context.page_title"},
      {&context.referrer, 2048, "context.referrer"}, {&context.locale, 16, "context.locale"},
      {&context.timezone, 64, "context.timezone"},   {&context.app_version, 32, "context.app.version"},
      {&context.app_build, 32, "context.app.build"},
  };
  for (const Limit& limit : limits) {
    Error error = validate_text(*limit.value, limit.max_length, limit.field);
    if (error.failed()) return error;
  }
  if (context.screen && (context.screen->first < 0 || context.screen->second < 0)) {
    return make_error(ErrorCode::invalid_event, "context.screen negatif olamaz");
  }
  return Error();
}

inline bool append_context(std::string& out, const Context& context) {
  std::string body;
  bool first = true;
  if (!append_field(body, first, "page_url", context.page_url) || !append_field(body, first, "page_title", context.page_title) ||
      !append_field(body, first, "referrer", context.referrer) || !append_field(body, first, "locale", context.locale) ||
      !append_field(body, first, "timezone", context.timezone)) {
    return false;
  }
  if (context.screen) {
    if (!first) body.push_back(',');
    first = false;
    body += "\"screen\":{\"width\":" + std::to_string(context.screen->first) + ",\"height\":" + std::to_string(context.screen->second) + "}";
  }
  std::string app;
  bool app_first = true;
  if (!append_field(app, app_first, "version", context.app_version) || !append_field(app, app_first, "build", context.app_build)) return false;
  if (!app.empty()) {
    if (!first) body.push_back(',');
    first = false;
    body += "\"app\":{" + app + "}";
  }
  if (!body.empty()) out += ",\"context\":{" + body + "}";
  return true;
}

// RFC 7807 gövdesinden kısa, loglanabilir özet (ham gövde sızdırılmaz).
inline std::string problem_summary(const std::string& raw) {
  Value problem;
  if (!parse_json(raw, problem) || !problem.is_object()) return "problem+json yok";
  std::string text;
  for (const char* key : {"title", "detail"}) {
    const Value* item = problem.find(key);
    if (item == nullptr || !item->is_string()) continue;
    const std::string part = trim(item->as_string());
    if (part.empty()) continue;
    if (!text.empty()) text.push_back(' ');
    text += part;
  }
  return text.empty() ? std::string("problem+json yok") : utf8_truncate(text, 200);
}

// ------------------------------------------------------------------ kuyruk ve teslim durum makinesi

// Üretim ve teslim kuralları tek yerde: izin kapısı, fr_click süzgeci, kuyruk sınırı, sabitlenmiş batch, geri çekilme.
// Ağ ve iş parçacığı çağırana aittir (sdks/cpp: std::thread + Transport, sdks/unreal: oyun iş parçacığı + FHttpModule).
class EventCore {
 public:
  EventCore(SdkIdentity sdk, int batch_limit, int queue_capacity, const Consent& initial_consent)
      : identity_(std::move(sdk)),
        batch_size_(std::max(1, std::min(batch_limit, kMaxBatchSize))),
        queue_limit_(std::max(1, queue_capacity)),
        consent_(initial_consent) {}

  const SdkIdentity& identity() const { return identity_; }
  const Consent& consent() const { return consent_; }
  const std::string& user_id() const { return user_id_; }
  int batch_size() const { return batch_size_; }
  int queue_limit() const { return queue_limit_; }
  std::size_t queued() const { return queue_.size(); }
  std::int64_t dropped() const { return dropped_; }
  std::int64_t backoff_ms() const { return backoff_ms_; }
  bool in_backoff(std::int64_t monotonic_ms) const { return monotonic_ms < backoff_until_ms_; }

  // Üretici sürekli ekliyorsa gönderim döngüsü sonsuz olmasın: kuyruk sınırı kadar olay + bir tur.
  int max_rounds() const { return queue_limit_ / batch_size_ + 2; }

  // analytics false ise bekleyen olaylar atılır ve yeni olay üretilmez.
  void set_consent(const Consent& next) {
    consent_ = next;
    if (!next.analytics) {
      queue_.clear();
      pinned_.clear();
      has_pinned_ = false;
    }
  }

  // Sonraki olaylar için varsayılan user_id (olay başına user_id önceliklidir). Boş değer varsayılanı kaldırır.
  Error identify(const std::string& next) {
    Error error = validate_text(next, kMaxIdentifierLength, "user_id");
    if (!error.failed()) user_id_ = next;
    return error;
  }

  // Doğrular, UTP v1 biçimine çevirir, kuyruğa ekler; ağ çağrısı yapmaz. properties null veya nesne olmalıdır.
  TrackOutcome track(const std::string& event_name, const Value& properties, const TrackOptions& options, std::int64_t now_ms, const RandomFill& fill) {
    TrackOutcome out;
    if (!consent_.analytics) return out;

    if (!valid_event_name(event_name)) {
      out.error = make_error(ErrorCode::invalid_event, "event_name snake_case olmalı (^[a-z][a-z0-9_]*$, en fazla 100 karakter)");
      return out;
    }
    if (!properties.is_null() && !properties.is_object()) {
      out.error = make_error(ErrorCode::invalid_event, "properties bir JSON nesnesi olmalı");
      return out;
    }
    if (properties.size() > kMaxProperties) {
      out.error = make_error(ErrorCode::invalid_event, "properties en fazla 100 anahtar içerebilir (" + std::to_string(properties.size()) + " verildi)");
      return out;
    }
    if (properties.is_object()) {
      for (std::size_t i = 0; i < properties.size(); ++i) {
        if (!valid_property_key(properties.key_at(i))) {
          out.error = make_error(ErrorCode::invalid_event, "properties anahtarı ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ desenine uymalı");
          return out;
        }
      }
    }
    out.error = validate_text(options.user_id, kMaxIdentifierLength, "user_id");
    if (out.error.failed()) return out;
    out.error = validate_text(options.anonymous_id, kMaxIdentifierLength, "anonymous_id");
    if (out.error.failed()) return out;
    out.error = validate_text(options.session_id, kMaxIdentifierLength, "session_id");
    if (out.error.failed()) return out;
    if (options.context) {
      out.error = validate_context(*options.context);
      if (out.error.failed()) return out;
    }
    const std::int64_t occurred = options.occurred_at_ms ? *options.occurred_at_ms : now_ms;
    if (occurred < 0 || occurred > kMaxTimestampMs) {
      out.error = make_error(ErrorCode::invalid_event, "occurred_at 1970 ile 9999 arasında olmalı");
      return out;
    }

    // fr_click yalnız açık reklam ölçümü izniyle gönderilir.
    Value filtered = properties;
    if (filtered.is_object() && !consent_.advertising) filtered.erase(attribution_click_property());

    const std::string event_id = ulid_.next(now_ms, fill);
    std::string json = "{\"event_id\":\"" + event_id + "\",\"event_name\":\"" + event_name + "\",\"occurred_at\":\"" + format_time(occurred) + "\",\"platform\":";
    bool encoded = append_json_string(json, identity_.platform);
    json += ",\"schema_version\":" + std::to_string(kSchemaVersion) + ",\"sdk\":{\"name\":";
    encoded = encoded && append_json_string(json, identity_.name);
    json += ",\"version\":";
    encoded = encoded && append_json_string(json, identity_.version);
    json += "},\"consent\":";
    append_consent(json, consent_);
    bool none_written = false;
    const std::string& user = options.user_id.empty() ? user_id_ : options.user_id;
    encoded = encoded && append_field(json, none_written, "anonymous_id", options.anonymous_id);
    encoded = encoded && append_field(json, none_written, "user_id", user);
    encoded = encoded && append_field(json, none_written, "session_id", options.session_id);
    if (filtered.is_object() && filtered.size() > 0) {
      json += ",\"properties\":";
      encoded = encoded && append_json(json, filtered);
    }
    if (options.context) encoded = encoded && append_context(json, *options.context);
    json.push_back('}');
    // Serileştirme kuyruğa eklemeden önce yapılır; bozuk bir olay batch'i zehirleyemez.
    if (!encoded) {
      out.error = make_error(ErrorCode::invalid_event, "olay JSON'a dönüştürülemedi (geçersiz UTF-8, NaN, sonsuz veya çok derin değer)");
      return out;
    }

    out.produced = true;
    out.event_id = event_id;
    out.event_json = json;
    QueuedEvent item;
    item.id = event_id;
    item.json = std::move(json);
    queue_.push_back(std::move(item));
    while (queue_.size() > static_cast<std::size_t>(queue_limit_)) {
      queue_.pop_front();
      ++dropped_;
      ++out.dropped_now;
    }
    out.queue_full = queue_.size() >= static_cast<std::size_t>(batch_size_);
    return out;
  }

  // Kalıcı depodan okunan, önceden serileştirilmiş olayı event_id'sini koruyarak kuyruğa ekler (tekrar gönderimde aynı kimlik).
  // İzin yoksa eklenmez. Sınır aşılırsa en eski olay atılır; atılan olayların kimlikleri dropped_ids'e yazılır.
  bool restore(QueuedEvent item, std::vector<std::string>& dropped_ids) {
    if (!consent_.analytics) return false;
    queue_.push_back(std::move(item));
    while (queue_.size() > static_cast<std::size_t>(queue_limit_)) {
      dropped_ids.push_back(queue_.front().id);
      queue_.pop_front();
      ++dropped_;
    }
    return true;
  }

  // Gönderilecek sıradaki batch. Sonucu bilinmeyen batch aynı içerik ve aynı anahtarla yeniden denenir; sunucu yanıtı
  // yolda kaybolduysa araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
  Batch peek() const {
    if (has_pinned_) return pinned_;
    const std::size_t count = std::min(queue_.size(), static_cast<std::size_t>(batch_size_));
    return Batch(queue_.begin(), queue_.begin() + static_cast<std::ptrdiff_t>(count));
  }

  static std::string batch_key(const Batch& batch) {
    std::vector<std::string> ids;
    ids.reserve(batch.size());
    for (const QueuedEvent& item : batch) ids.push_back(item.id);
    return idempotency_key_for(std::move(ids));
  }

  // Olaylar zaten serileştirilmiş; gövde metin birleştirme ile kurulur.
  static std::string batch_body(const Batch& batch, std::int64_t now_ms) {
    std::string body = "{\"sent_at\":\"" + format_time(now_ms) + "\",\"events\":[";
    for (std::size_t i = 0; i < batch.size(); ++i) {
      if (i != 0) body.push_back(',');
      body += batch[i].json;
    }
    body += "]}";
    return body;
  }

  // HTTP yanıtı alındı: 202 kabul; 401/403 bütün kuyruk atılır (anahtar geçersizse kalan olaylar da aynı sonucu alır);
  // öteki 4xx (429 hariç) yalnız bu batch atılır; 5xx, 429 ve diğerleri kuyrukta kalır.
  DeliveryResult on_response(const Batch& batch, int status, const std::string& body, const std::string& retry_after, std::int64_t monotonic_ms) {
    DeliveryResult result;
    const int count = static_cast<int>(batch.size());
    result.sent = count;
    result.status = status;
    if (status == 202) {
      acknowledge(batch);
      backoff_ms_ = 0;
      backoff_until_ms_ = 0;
      result.accepted = count;
      Value ack;
      if (parse_json(body, ack) && ack.is_object()) {
        const Value* accepted = ack.find("accepted");
        const Value* rejected = ack.find("rejected");
        const Value* batch_id = ack.find("batch_id");
        if (accepted != nullptr && accepted->is_integer()) result.accepted = static_cast<int>(accepted->as_int());
        if (rejected != nullptr && rejected->is_integer()) result.rejected = static_cast<int>(rejected->as_int());
        if (batch_id != nullptr && batch_id->is_string()) result.batch_id = batch_id->as_string();
      }
      return result;
    }
    if (status >= 400 && status < 500 && status != 429) {
      acknowledge(batch);
      result.rejected = count;
      if (status == 401 || status == 403) {
        result.rejected += static_cast<int>(queue_.size());
        queue_.clear();
      }
      result.error = make_error(ErrorCode::rejected, "HTTP " + std::to_string(status) + ": " + problem_summary(body), status);
      return result;
    }
    pin(batch);
    note_failure(retry_after, monotonic_ms);
    result.retained = count;
    result.error = make_error(ErrorCode::temporary, "HTTP " + std::to_string(status) + "; olaylar kuyrukta tutuldu", status);
    return result;
  }

  // Ağ hatası veya zaman aşımı: sonuç bilinmiyor, batch sabitlenir.
  DeliveryResult on_network_error(const Batch& batch, const std::string& message, std::int64_t monotonic_ms) {
    DeliveryResult result;
    pin(batch);
    note_failure(std::string(), monotonic_ms);
    result.sent = static_cast<int>(batch.size());
    result.retained = result.sent;
    result.error = make_error(ErrorCode::temporary, "ağ hatası: " + message);
    return result;
  }

 private:
  void acknowledge(const Batch& batch) {
    has_pinned_ = false;
    pinned_.clear();
    std::set<std::string> ids;
    for (const QueuedEvent& item : batch) ids.insert(item.id);
    queue_.erase(std::remove_if(queue_.begin(), queue_.end(), [&ids](const QueuedEvent& item) { return ids.count(item.id) != 0; }), queue_.end());
  }

  // İstek sürerken izin geri çekildiyse olaylar çoktan silinmiştir, sabitlenmez.
  void pin(const Batch& batch) {
    if (consent_.analytics) {
      pinned_ = batch;
      has_pinned_ = true;
    }
  }

  // Üstel geri çekilme 1 sn → 30 sn; Retry-After verilmişse en az o kadar beklenir.
  // Yarım jitter: aynı anda yeniden başlayan süreçler toplayıcıya birlikte yüklenmez.
  void note_failure(const std::string& retry_after, std::int64_t monotonic_ms) {
    std::int64_t next = std::max(backoff_ms_ * 2, kMinBackoffMs);
    std::int64_t floor_ms = 0;
    const std::string seconds = trim(retry_after);
    if (!seconds.empty() && seconds.size() <= 6 && std::all_of(seconds.begin(), seconds.end(), ascii_digit)) {
      std::int64_t parsed = 0;
      for (const char c : seconds) parsed = parsed * 10 + (c - '0');
      floor_ms = std::min(parsed * 1000, kMaxBackoffMs);
      next = std::max(next, parsed * 1000);
    }
    next = std::min(next, kMaxBackoffMs);
    backoff_ms_ = next;
    const std::int64_t half = next / 2;
    backoff_until_ms_ = monotonic_ms + std::max(floor_ms, half + static_cast<std::int64_t>(next_jitter(monotonic_ms) % static_cast<std::uint64_t>(next - half + 1)));
  }

  // Kriptografik olmayan xorshift64: yalnız bekleme süresini dağıtır. Süreçler ayrışsın diye nesne adresi ve saatle tohumlanır.
  std::uint64_t next_jitter(std::int64_t monotonic_ms) {
    if (jitter_state_ == 0) {
      jitter_state_ = (static_cast<std::uint64_t>(reinterpret_cast<std::uintptr_t>(this)) ^ (static_cast<std::uint64_t>(monotonic_ms) << 21)) | 1u;
    }
    jitter_state_ ^= jitter_state_ << 13;
    jitter_state_ ^= jitter_state_ >> 7;
    jitter_state_ ^= jitter_state_ << 17;
    return jitter_state_;
  }

  SdkIdentity identity_;
  int batch_size_;
  int queue_limit_;
  Consent consent_;
  std::string user_id_;
  std::deque<QueuedEvent> queue_;
  Batch pinned_;
  bool has_pinned_ = false;
  std::int64_t dropped_ = 0;
  std::int64_t backoff_ms_ = 0;
  std::int64_t backoff_until_ms_ = 0;
  std::uint64_t jitter_state_ = 0;
  UlidGenerator ulid_;
};

}  // namespace wire
}  // namespace feralin

#endif  // FERALIN_WIRE_HPP
