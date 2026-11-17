// Feralin C++ SDK olay sözleşmeleri: gelir (`feralin_purchase`), profil (`fr_group`, `fr_user_properties`) ve hata (`fr_error`).
//
// Kurallar öteki SDK'larla birebir aynıdır: gelir packages/sdk-web/src/index.ts buildRevenueProperties ve sdks/go/revenue.go;
// profil sdks/go/profile.go ve toplayıcıdaki services/collect/internal/httpapi/profile_filter.go; hata Android ErrorEvent.kt,
// sdks/react-native/src/signals.ts ve services/collect/internal/httpapi/error_adrevenue_filter.go.
//
// Bu dosya yalnız sdks/cpp içindir (Unreal eklentisinin kendi FeralinGame.hpp sözleşmesi vardır); wire.hpp ile aynı biçimde
// motor ve ağdan bağımsızdır, exception ve RTTI gerektirmez.
#ifndef FERALIN_SIGNALS_HPP
#define FERALIN_SIGNALS_HPP

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

#include "feralin/wire.hpp"

namespace feralin {
namespace signals {

using wire::Value;

// ------------------------------------------------------------------ ortak yardımcılar

// Kod noktası çözer; geçersiz UTF-8'de false döner ve i bir bayt ilerler.
inline bool decode_utf8(const std::string& text, std::size_t& i, std::uint32_t& point) {
  const std::size_t start = i;
  if (!wire::utf8_step(text, i)) {
    i = start + 1;
    return false;
  }
  const auto byte = [&text](std::size_t at) { return static_cast<std::uint32_t>(static_cast<unsigned char>(text[at])); };
  const std::size_t length = i - start;
  if (length == 1) point = byte(start);
  else if (length == 2) point = ((byte(start) & 0x1Fu) << 6) | (byte(start + 1) & 0x3Fu);
  else if (length == 3) point = ((byte(start) & 0x0Fu) << 12) | ((byte(start + 1) & 0x3Fu) << 6) | (byte(start + 2) & 0x3Fu);
  else point = ((byte(start) & 0x07u) << 18) | ((byte(start + 1) & 0x3Fu) << 12) | ((byte(start + 2) & 0x3Fu) << 6) | (byte(start + 3) & 0x3Fu);
  return true;
}

// Go unicode.IsControl ile aynı küme (Cc): U+0000-U+001F ve U+007F-U+009F.
inline bool is_control_point(std::uint32_t point) { return point < 0x20u || (point >= 0x7Fu && point <= 0x9Fu); }

inline bool has_control_or_invalid(const std::string& text) {
  std::size_t i = 0;
  while (i < text.size()) {
    std::uint32_t point = 0;
    if (!decode_utf8(text, i, point) || is_control_point(point)) return true;
  }
  return false;
}

// Geçersiz UTF-8 baytı ve kontrol karakteri boşluğa çevrilir: JSON yazıcı NUL ve bozuk metni reddeder, hata metni yine gitsin.
inline std::string clean_text(const std::string& text) {
  std::string out;
  out.reserve(text.size());
  std::size_t i = 0;
  while (i < text.size()) {
    const std::size_t start = i;
    std::uint32_t point = 0;
    if (!decode_utf8(text, i, point) || is_control_point(point)) {
      out.push_back(' ');
      continue;
    }
    out.append(text, start, i - start);
  }
  return out;
}

// RE2 \s kümesi (ASCII): boşluk, \t, \n, \f, \r. \v de boşluk sayılır (Kotlin ve JS ile aynı).
inline bool ascii_space(char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\f' || c == '\r' || c == '\v'; }

// Ardışık boşlukları tek boşluğa indirir ve kırpar.
inline std::string collapse_spaces(const std::string& text) {
  std::string out;
  out.reserve(text.size());
  bool pending = false;
  for (const char c : text) {
    if (ascii_space(c)) {
      pending = !out.empty();
      continue;
    }
    if (pending) out.push_back(' ');
    pending = false;
    out.push_back(c);
  }
  return out;
}

inline std::size_t code_points(const std::string& text) {
  std::size_t length = 0;
  return wire::utf8_length(text, length) ? length : text.size();
}

// ------------------------------------------------------------------ gelir (feralin_purchase)

constexpr const char* kRevenueEventName = "feralin_purchase";
// Küçük birimde tutarın üst sınırı (JS güvenli tam sayı, 2^53-1).
constexpr std::int64_t kMaxAmountMinor = 9007199254740991LL;
constexpr int kMaxQuantity = 100000;

struct Receipt {
  std::string provider;  // apple, google veya stripe
  std::string token;     // 1..8192 karakter; toplayıcı yalnız sağlayıcıyı ve özetini saklar
};

// İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar; `verified` hiçbir zaman gönderilmez.
struct RevenueInput {
  std::string transaction_id;          // 1..128; sunucu aynı işlemi ikinci kez saymaz
  std::int64_t amount_minor = 0;       // küçük birimde satır toplamı (49,99 TL → 4999); abonelik iptalinde 0
  std::string currency;                // ISO 4217, üç büyük harf
  std::string product_id;              // boş: gönderilmez; en çok 128
  int quantity = 1;                    // 0..100000
  std::string purchase_type;           // boş: "purchase"
  std::optional<Receipt> receipt;
  Value properties;                    // null ya da nesne; doğrulama alanları düşer
};

// İstemcinin beyan edemeyeceği alanlar: çağıranın özelliklerinden düşürülür, sunucu da düşürür.
inline const std::vector<std::string>& revenue_reserved_keys() {
  static const std::vector<std::string> keys = {"verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"};
  return keys;
}

inline bool valid_currency(const std::string& currency) {
  return currency.size() == 3 && std::all_of(currency.begin(), currency.end(), [](char c) { return c >= 'A' && c <= 'Z'; });
}

// 1..max kod noktası, geçerli UTF-8 ve NUL içermeyen metin.
inline bool text_within(const std::string& text, std::size_t max) {
  std::size_t length = 0;
  return !text.empty() && text.find('\0') == std::string::npos && wire::utf8_length(text, length) && length <= max;
}

// Gelir girdisini sözleşme özelliklerine çevirir; geçersiz girdide nullopt (olay üretilmez).
inline std::optional<Value> revenue_properties(const RevenueInput& in) {
  if (!text_within(in.transaction_id, 128)) return std::nullopt;
  if (in.amount_minor < 0 || in.amount_minor > kMaxAmountMinor) return std::nullopt;
  if (!valid_currency(in.currency)) return std::nullopt;
  if (!in.product_id.empty() && !text_within(in.product_id, 128)) return std::nullopt;
  if (in.quantity < 0 || in.quantity > kMaxQuantity) return std::nullopt;
  const std::string purchase_type = in.purchase_type.empty() ? std::string("purchase") : in.purchase_type;
  if (purchase_type != "purchase" && purchase_type != "subscription_start" && purchase_type != "subscription_renew" && purchase_type != "subscription_cancel") {
    return std::nullopt;
  }
  // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
  if (purchase_type == "subscription_cancel" && in.amount_minor != 0) return std::nullopt;
  if (in.receipt) {
    const std::string& provider = in.receipt->provider;
    if (provider != "apple" && provider != "google" && provider != "stripe") return std::nullopt;
    if (!text_within(in.receipt->token, 8192)) return std::nullopt;
  }
  if (!in.properties.is_null() && !in.properties.is_object()) return std::nullopt;

  Value props = in.properties.is_object() ? in.properties : Value::make_object();
  for (const std::string& key : revenue_reserved_keys()) props.erase(key);
  props.set("transaction_id", in.transaction_id);
  props.set("amount_minor", in.amount_minor);
  props.set("currency", in.currency);
  props.set("quantity", in.quantity);
  props.set("purchase_type", purchase_type);
  if (!in.product_id.empty()) props.set("product_id", in.product_id);
  if (in.receipt) {
    Value receipt = Value::make_object();
    receipt.set("provider", in.receipt->provider);
    receipt.set("token", in.receipt->token);
    props.set("receipt", receipt);
  }
  return props;
}

// ------------------------------------------------------------------ profil (fr_group, fr_user_properties)

constexpr const char* kGroupEventName = "fr_group";
constexpr const char* kUserPropertiesEventName = "fr_user_properties";
constexpr std::size_t kMaxProfileProperties = 50;
constexpr std::size_t kMaxProfileValueLength = 256;
constexpr std::size_t kMaxGroupIdLength = 128;

// Anahtarı belirteçlere ayırır: camelCase sınırında ve alt çizgide böler, küçük harfe çevirir (Go profileKeyTokens ile aynı).
inline std::vector<std::string> profile_key_tokens(const std::string& key) {
  std::string spaced;
  for (std::size_t i = 0; i < key.size(); ++i) {
    const char c = key[i];
    const bool upper = c >= 'A' && c <= 'Z';
    if (i > 0 && upper) {
      const char previous = key[i - 1];
      if ((previous >= 'a' && previous <= 'z') || wire::ascii_digit(previous)) spaced.push_back('_');
    }
    spaced.push_back(upper ? static_cast<char>(c - 'A' + 'a') : c);
  }
  std::vector<std::string> tokens;
  std::string current;
  for (const char c : spaced) {
    if (c == '_') {
      if (!current.empty()) tokens.push_back(current);
      current.clear();
    } else {
      current.push_back(c);
    }
  }
  if (!current.empty()) tokens.push_back(current);
  return tokens;
}

// Anahtar kişisel veriye benziyor mu (toplayıcıdaki piiTokens, piiFragments ve piiExact listeleriyle birebir).
inline bool is_pii_like_key(const std::string& key) {
  static const char* const kTokens[] = {"email", "mail", "phone", "tel", "telephone", "mobile", "msisdn", "gsm", "ip", "ipv4", "ipv6",
                                        "ssn", "tckn", "passport", "password", "iban", "address", "adres", "eposta", "telefon", "soyad",
                                        "surname", "firstname", "lastname", "fullname", "birthdate", "birthday", "dob"};
  static const char* const kFragments[] = {"email", "phonenumber", "ipaddress", "firstname", "lastname", "fullname",
                                           "surname", "soyad", "eposta", "telefon", "password", "birthdate"};
  static const char* const kExact[] = {"name", "username", "displayname", "isim", "ad"};
  const std::vector<std::string> tokens = profile_key_tokens(key);
  std::string joined;
  for (const std::string& token : tokens) {
    for (const char* denied : kTokens) {
      if (token == denied) return true;
    }
    joined += token;
  }
  for (const char* exact : kExact) {
    if (joined == exact) return true;
  }
  for (const char* fragment : kFragments) {
    if (joined.find(fragment) != std::string::npos) return true;
  }
  return false;
}

// Go profileEmailRe `[^\s@]+@[^\s@]+\.[^\s@]+` ile aynı: değerin herhangi bir yerinde e-posta biçimi.
inline bool looks_like_email(const std::string& text) {
  const auto plain = [](char c) { return c != '@' && !ascii_space(c); };
  for (std::size_t at = text.find('@'); at != std::string::npos; at = text.find('@', at + 1)) {
    if (at == 0 || !plain(text[at - 1])) continue;
    std::size_t end = at + 1;
    while (end < text.size() && plain(text[end])) ++end;
    // Etki alanı parçasında baştan ve sondan en az bir karakter uzakta nokta olmalı.
    for (std::size_t dot = at + 2; dot + 1 < end; ++dot) {
      if (text[dot] == '.') return true;
    }
  }
  return false;
}

inline bool profile_reserved_key(const std::string& key) {
  const auto& reserved = revenue_reserved_keys();
  return std::find(reserved.begin(), reserved.end(), key) != reserved.end();
}

inline bool valid_profile_key(const std::string& key) {
  return wire::valid_property_key(key) && !is_pii_like_key(key) && !profile_reserved_key(key);
}

// Değer dizge (≤256, kontrol karakteri yok, e-posta biçiminde değil), sonlu sayı ya da bool olmalı; nesne, dizi ve null düşer.
inline bool valid_profile_value(const Value& value) {
  switch (value.type()) {
    case Value::Type::string:
      return !has_control_or_invalid(value.as_string()) && code_points(value.as_string()) <= kMaxProfileValueLength && !looks_like_email(value.as_string());
    case Value::Type::boolean:
    case Value::Type::integer:
      return true;
    case Value::Type::real:
      return std::isfinite(value.as_double());
    default:
      return false;
  }
}

// Özellikleri sözleşmeye indirger; geçersiz anahtar ve değer düşer. Sınırı aşan fazlalık sözlük sırasına göre düşer (Go ile aynı).
inline Value sanitize_profile_properties(const Value& properties) {
  Value out = Value::make_object();
  if (!properties.is_object()) return out;
  std::map<std::string, std::size_t> sorted;
  for (std::size_t i = 0; i < properties.size(); ++i) sorted[properties.key_at(i)] = i;
  for (const auto& entry : sorted) {
    if (out.size() >= kMaxProfileProperties) break;
    const Value& value = properties.at(entry.second);
    if (valid_profile_key(entry.first) && valid_profile_value(value)) out.set(entry.first, value);
  }
  return out;
}

// Grup kimliği: 1-128 karakter, boşluktan ibaret değil, `@` ve kontrol karakteri içermez.
inline bool valid_group_id(const std::string& id) {
  if (wire::trim(id).empty() || has_control_or_invalid(id) || code_points(id) > kMaxGroupIdLength) return false;
  return id.find('@') == std::string::npos;
}

// ------------------------------------------------------------------ hata (fr_error)

constexpr const char* kErrorEventName = "fr_error";
constexpr const char* kErrorOriginHandled = "handled";
constexpr const char* kErrorOriginManual = "manual";
constexpr const char* kErrorOriginUncaught = "uncaught_exception";
constexpr std::size_t kMaxErrorMessage = 200;
constexpr std::size_t kMaxErrorType = 64;
constexpr std::size_t kMaxErrorFrame = 160;
constexpr std::size_t kMaxErrorFrames = 50;
constexpr std::size_t kFingerprintFrames = 5;
constexpr std::size_t kMaxAppVersion = 32;

// FNV-1a 64 bit (Web, React Native ve Flutter SDK'larıyla aynı özet), UTF-8 baytları üzerinden: 16 küçük harf onaltılı.
inline std::string fnv1a64(const std::string& text) {
  std::uint64_t hash = 0xCBF29CE484222325ull;
  for (const char c : text) {
    hash ^= static_cast<unsigned char>(c);
    hash *= 0x100000001B3ull;
  }
  static const char kHex[] = "0123456789abcdef";
  std::string out(16, '0');
  for (std::size_t i = 16; i > 0; --i) {
    out[i - 1] = kHex[hash & 0x0Fu];
    hash >>= 4;
  }
  return out;
}

namespace detail {

// RE2 \b için ASCII sözcük karakteri; çok baytlı UTF-8 baytları sözcük sayılmaz.
inline bool word_char(const std::string& text, std::size_t i) {
  if (i >= text.size()) return false;
  const char c = text[i];
  return wire::ascii_alpha(c) || wire::ascii_digit(c) || c == '_';
}

inline bool boundary(const std::string& text, std::size_t i) {
  const bool before = i > 0 && word_char(text, i - 1);
  return before != word_char(text, i);
}

inline bool hex_char(char c) { return wire::ascii_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

// (?i)\b[a-z][a-z0-9+.-]*://[^\s"'<>]+  →  [url]
inline std::string scrub_urls(const std::string& text) {
  const auto scheme_char = [](char c) { return wire::ascii_alpha(c) || wire::ascii_digit(c) || c == '+' || c == '.' || c == '-'; };
  const auto stop = [](char c) { return ascii_space(c) || c == '"' || c == '\'' || c == '<' || c == '>'; };
  std::string out;
  std::size_t p = 0;
  while (p < text.size()) {
    if (wire::ascii_alpha(text[p]) && boundary(text, p)) {
      std::size_t q = p + 1;
      while (q < text.size() && scheme_char(text[q])) ++q;
      if (text.compare(q, 3, "://") == 0 && q + 3 < text.size() && !stop(text[q + 3])) {
        std::size_t end = q + 3;
        while (end < text.size() && !stop(text[end])) ++end;
        out += "[url]";
        p = end;
        continue;
      }
    }
    out.push_back(text[p++]);
  }
  return out;
}

// [A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}  →  [email]
inline std::string scrub_emails(const std::string& text) {
  const auto local_char = [](char c) { return wire::ascii_alpha(c) || wire::ascii_digit(c) || c == '.' || c == '_' || c == '%' || c == '+' || c == '-'; };
  const auto domain_char = [](char c) { return wire::ascii_alpha(c) || wire::ascii_digit(c) || c == '.' || c == '-'; };
  std::string out;
  std::size_t copied = 0;
  for (std::size_t at = text.find('@'); at != std::string::npos; at = text.find('@', at + 1)) {
    std::size_t start = at;
    while (start > copied && local_char(text[start - 1])) --start;
    if (start == at) continue;
    std::size_t domain_end = at + 1;
    while (domain_end < text.size() && domain_char(text[domain_end])) ++domain_end;
    // Açgözlü eşleşme: en sağdaki uygun nokta seçilir (noktadan önce en az bir karakter, sonra en az iki harf).
    std::size_t end = std::string::npos;
    for (std::size_t dot = domain_end; dot > at + 2; --dot) {
      const std::size_t d = dot - 1;
      if (text[d] != '.') continue;
      std::size_t letters = d + 1;
      while (letters < text.size() && wire::ascii_alpha(text[letters])) ++letters;
      if (letters - (d + 1) >= 2) {
        end = letters;
        break;
      }
    }
    if (end == std::string::npos) continue;
    out.append(text, copied, start - copied);
    out += "[email]";
    copied = end;
    at = end - 1;
  }
  out.append(text, copied, std::string::npos);
  return out;
}

// (?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b  →  [id]
inline std::string scrub_uuids(const std::string& text) {
  static const std::size_t kGroups[] = {8, 4, 4, 4, 12};
  std::string out;
  std::size_t p = 0;
  while (p < text.size()) {
    if (hex_char(text[p]) && boundary(text, p)) {
      std::size_t q = p;
      bool ok = true;
      for (std::size_t g = 0; g < 5 && ok; ++g) {
        if (g > 0) {
          ok = q < text.size() && text[q] == '-';
          ++q;
        }
        for (std::size_t k = 0; k < kGroups[g] && ok; ++k, ++q) ok = q < text.size() && hex_char(text[q]);
      }
      if (ok && boundary(text, q)) {
        out += "[id]";
        p = q;
        continue;
      }
    }
    out.push_back(text[p++]);
  }
  return out;
}

// \b[A-Za-z0-9_\-+/=]{24,}\b, en az bir rakam içeriyorsa  →  [token]. Rakamsız uzun sınıf adları bozulmaz.
inline std::string scrub_tokens(const std::string& text) {
  const auto token_char = [](char c) { return wire::ascii_alpha(c) || wire::ascii_digit(c) || c == '_' || c == '-' || c == '+' || c == '/' || c == '='; };
  std::string out;
  std::size_t p = 0;
  while (p < text.size()) {
    if (token_char(text[p]) && boundary(text, p)) {
      std::size_t run = p;
      while (run < text.size() && token_char(text[run])) ++run;
      std::size_t end = std::string::npos;
      for (std::size_t e = run; e >= p + 24; --e) {
        if (boundary(text, e)) {
          end = e;
          break;
        }
      }
      if (end != std::string::npos) {
        const bool digit = std::any_of(text.begin() + static_cast<std::ptrdiff_t>(p), text.begin() + static_cast<std::ptrdiff_t>(end), wire::ascii_digit);
        if (digit) out += "[token]";
        else out.append(text, p, end - p);
        p = end;
        continue;
      }
    }
    out.push_back(text[p++]);
  }
  return out;
}

// \+?\d[\d\s\-().]{5,}\d, en az 7 rakam içeriyorsa  →  [num]. Kısa sürüm dizgeleri (1.4.2) bozulmaz.
inline std::string scrub_numbers(const std::string& text) {
  const auto middle_char = [](char c) { return wire::ascii_digit(c) || ascii_space(c) || c == '-' || c == '(' || c == ')' || c == '.'; };
  std::string out;
  std::size_t p = 0;
  while (p < text.size()) {
    std::size_t first = p;
    if (text[p] == '+' && p + 1 < text.size() && wire::ascii_digit(text[p + 1])) first = p + 1;
    if (wire::ascii_digit(text[first])) {
      std::size_t run = first + 1;
      while (run < text.size() && middle_char(text[run])) ++run;
      std::size_t end = std::string::npos;
      for (std::size_t last = run; last > first + 6; --last) {
        if (wire::ascii_digit(text[last - 1])) {
          end = last;
          break;
        }
      }
      if (end != std::string::npos) {
        const auto digits = std::count_if(text.begin() + static_cast<std::ptrdiff_t>(p), text.begin() + static_cast<std::ptrdiff_t>(end), wire::ascii_digit);
        if (digits >= 7) out += "[num]";
        else out.append(text, p, end - p);
        p = end;
        continue;
      }
    }
    out.push_back(text[p++]);
  }
  return out;
}

}  // namespace detail

// Mesajdan URL, e-posta, UUID, uzun belirteç ve uzun sayıları çıkarır; boşlukları sadeleştirir, 200 karaktere kırpar.
// Sıra toplayıcıyla aynıdır (URL e-postadan önce); toplayıcı aynı temizliği sunucuda tekrarlar.
inline std::string scrub_error_message(const std::string& message) {
  std::string text = clean_text(message);
  text = detail::scrub_urls(text);
  text = detail::scrub_emails(text);
  text = detail::scrub_uuids(text);
  text = detail::scrub_tokens(text);
  text = detail::scrub_numbers(text);
  return wire::utf8_truncate(collapse_spaces(text), kMaxErrorMessage);
}

// Hata türü: kontrol karakteri ve URL/e-posta çıkar, en çok 64 karakter; boşsa "Error".
inline std::string clean_error_type(const std::string& type) {
  std::string text = collapse_spaces(clean_text(type));
  text = detail::scrub_emails(detail::scrub_urls(text));
  text = wire::utf8_truncate(text, kMaxErrorType);
  return text.empty() ? std::string("Error") : text;
}

inline std::string replace_digit_runs(const std::string& text) {
  std::string out;
  bool in_digits = false;
  for (const char c : text) {
    if (wire::ascii_digit(c)) {
      if (!in_digits) out.push_back('#');
      in_digits = true;
    } else {
      out.push_back(c);
      in_digits = false;
    }
  }
  return out;
}

struct ErrorReport {
  std::string error_type;              // boş: "Error"
  std::string message;                 // ham mesaj; gövdeye yalnız temizlenmiş hali girer
  std::vector<std::string> frames;     // normalize çerçeveler (işlev@modül); satır, sütun ve yol içermemeli
  std::string origin = kErrorOriginHandled;
  bool fatal = false;
};

// Hata gövdesi: sözleşme alanlarının tamamı. Ham yığın izi, dosya yolu ve kullanıcı verisi GİTMEZ.
inline Value error_properties(const ErrorReport& report, const std::string& app_version) {
  const std::string type = clean_error_type(report.error_type);
  const std::string message = scrub_error_message(report.message);
  std::vector<std::string> frames;
  for (const std::string& raw : report.frames) {
    if (frames.size() >= kMaxErrorFrames) break;
    const std::string frame = collapse_spaces(clean_text(raw));
    if (!frame.empty()) frames.push_back(frame);
  }
  std::string basis;
  if (!frames.empty()) {
    for (std::size_t i = 0; i < frames.size() && i < kFingerprintFrames; ++i) {
      if (i > 0) basis.push_back('|');
      basis += frames[i];
    }
  } else {
    basis = replace_digit_runs(message);
  }
  const std::string origin = report.origin.empty() ? std::string(kErrorOriginHandled) : report.origin;
  Value props = Value::make_object();
  props.set("error_type", type);
  if (!message.empty()) props.set("message", message);
  props.set("fingerprint", fnv1a64(type + "|" + basis));
  if (!frames.empty()) props.set("top_frame", wire::utf8_truncate(frames.front(), kMaxErrorFrame));
  props.set("frame_count", static_cast<std::int64_t>(std::min<std::size_t>(frames.size(), 1000)));
  const std::size_t version_length = code_points(app_version);
  if (!app_version.empty() && version_length <= kMaxAppVersion && !has_control_or_invalid(app_version)) props.set("app_version", app_version);
  props.set("handled", origin == kErrorOriginHandled || origin == kErrorOriginManual);
  props.set("fatal", report.fatal);
  props.set("origin", origin);
  return props;
}

inline bool known_error_origin(const std::string& origin) {
  return origin.empty() || origin == kErrorOriginHandled || origin == kErrorOriginManual || origin == kErrorOriginUncaught;
}

// Hata fırtınası sınırı: süreç başına en çok max_events olay, aynı parmak izi için en çok max_per_fingerprint; örnekleme
// sample_rate ile (0..1). Rastgele değer çağırandan gelir. İş parçacığı güvenli değildir; kilidi çağıran sağlar.
class ErrorLimiter {
 public:
  explicit ErrorLimiter(double sample_rate = 1.0, int max_events = 20, int max_per_fingerprint = 3)
      : sample_rate_(std::isfinite(sample_rate) ? std::min(1.0, std::max(0.0, sample_rate)) : 1.0),
        max_events_(max_events),
        max_per_fingerprint_(max_per_fingerprint) {}

  bool allow(const std::string& fingerprint, double random_unit) {
    if (total_ >= max_events_) return false;
    if (sample_rate_ < 1.0 && random_unit >= sample_rate_) return false;
    int& seen = per_fingerprint_[fingerprint];
    if (seen >= max_per_fingerprint_) return false;
    ++seen;
    ++total_;
    return true;
  }

 private:
  double sample_rate_;
  int max_events_;
  int max_per_fingerprint_;
  int total_ = 0;
  std::map<std::string, int> per_fingerprint_;
};

}  // namespace signals
}  // namespace feralin

#endif  // FERALIN_SIGNALS_HPP
