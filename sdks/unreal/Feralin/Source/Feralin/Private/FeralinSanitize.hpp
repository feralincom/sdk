// Hata verisinden kişisel veri ve değişken parçaları ayıklar, yığın çerçevelerini normalleştirir, parmak izi özeti çıkarır.
//
// Sözleşme kaynağı sdks/unity/Runtime/Core/ErrorCapture.cs (ErrorSanitizer): aynı adımlar, aynı sıra, aynı sonuç. Unity'deki
// düzenli ifadeler burada elle yazılmış tarayıcılardır (exception ve RTTI kapalı derlemede std::regex güvenilmez). Sonuçlar
// tests/vectors/sdk_vectors.json içindeki Unity çıktılarıyla birebir karşılaştırılır.
//
// Bilinen yaklaşıklık: .NET'te \d, \s ve \b Unicode'dur. \s ve boşluk kırpma .NET ile aynı kümeyi kullanır; \d yalnız ASCII
// rakamdır; \b için ASCII dışı her kod birimi (BMP dışı vekiller dahil) harf sayılır, bilinen noktalama ve boşluk blokları hariç.
#ifndef FERALIN_SANITIZE_HPP
#define FERALIN_SANITIZE_HPP

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "FeralinSha256.hpp"

namespace feralin {
namespace sanitize {

using U16 = std::u16string;

// ---------------------------------------------------------------- UTF-8 <-> UTF-16

// Geçersiz UTF-8 dizisi U+FFFD olur; oyuna hata fırlatılmaz.
inline U16 to_u16(const std::string& text) {
  U16 out;
  out.reserve(text.size());
  std::size_t i = 0;
  while (i < text.size()) {
    const unsigned char lead = static_cast<unsigned char>(text[i]);
    std::uint32_t point = 0xFFFDu;
    std::size_t length = 1;
    if (lead < 0x80) {
      point = lead;
    } else if (lead >= 0xC2 && lead <= 0xDF) {
      length = 2;
      point = lead & 0x1Fu;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
      length = 3;
      point = lead & 0x0Fu;
    } else if (lead >= 0xF0 && lead <= 0xF4) {
      length = 4;
      point = lead & 0x07u;
    }
    if (length > 1) {
      bool good = i + length <= text.size();
      for (std::size_t k = 1; good && k < length; ++k) {
        const unsigned char next = static_cast<unsigned char>(text[i + k]);
        if ((next & 0xC0u) != 0x80u) {
          good = false;
        } else {
          point = (point << 6) | (next & 0x3Fu);
        }
      }
      if (!good || (length == 3 && (point < 0x800u || (point >= 0xD800u && point <= 0xDFFFu))) || (length == 4 && (point < 0x10000u || point > 0x10FFFFu))) {
        point = 0xFFFDu;
        length = 1;
      }
    }
    if (point >= 0x10000u) {
      const std::uint32_t shifted = point - 0x10000u;
      out.push_back(static_cast<char16_t>(0xD800u + (shifted >> 10)));
      out.push_back(static_cast<char16_t>(0xDC00u + (shifted & 0x3FFu)));
    } else {
      out.push_back(static_cast<char16_t>(point));
    }
    i += length;
  }
  return out;
}

inline void append_utf8(std::string& out, std::uint32_t point) {
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

// Kırpmada ikiye bölünmüş vekil çift U+FFFD olur (geçerli UTF-8 üretmek için).
inline std::string to_utf8(const U16& text) {
  std::string out;
  out.reserve(text.size());
  for (std::size_t i = 0; i < text.size(); ++i) {
    const std::uint32_t unit = text[i];
    if (unit >= 0xD800u && unit <= 0xDBFFu && i + 1 < text.size() && text[i + 1] >= 0xDC00u && text[i + 1] <= 0xDFFFu) {
      append_utf8(out, 0x10000u + ((unit - 0xD800u) << 10) + (static_cast<std::uint32_t>(text[i + 1]) - 0xDC00u));
      ++i;
    } else if (unit >= 0xD800u && unit <= 0xDFFFu) {
      append_utf8(out, 0xFFFDu);
    } else {
      append_utf8(out, unit);
    }
  }
  return out;
}

// ---------------------------------------------------------------- sınıflar

inline bool is_space(char16_t c) {
  return (c >= 0x09 && c <= 0x0D) || c == 0x20 || c == 0x85 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) || c == 0x2028 ||
         c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000;
}
inline bool is_digit(char16_t c) { return c >= u'0' && c <= u'9'; }
inline bool is_alpha(char16_t c) { return (c >= u'a' && c <= u'z') || (c >= u'A' && c <= u'Z'); }
inline bool is_hex(char16_t c) { return is_digit(c) || (c >= u'a' && c <= u'f') || (c >= u'A' && c <= u'F'); }

// \w yaklaşıklığı: ASCII harf, rakam, alt çizgi; ASCII dışında boşluk, noktalama ve simge blokları dışındaki her şey.
inline bool is_word(char16_t c) {
  if (c < 0x80) return is_alpha(c) || is_digit(c) || c == u'_';
  if (is_space(c)) return false;
  if (c >= 0xA1 && c <= 0xBF) return c == 0xAA || c == 0xB2 || c == 0xB3 || c == 0xB5 || c == 0xB9 || c == 0xBA || (c >= 0xBC && c <= 0xBE);
  if (c == 0xD7 || c == 0xF7) return false;
  if (c >= 0x2010 && c <= 0x2BFF) return false;
  if (c >= 0x3001 && c <= 0x3004) return false;
  return true;
}

inline char16_t lower(char16_t c) { return (c >= u'A' && c <= u'Z') ? static_cast<char16_t>(c + 32) : c; }

// Harfe duyarsız ASCII karşılaştırma; literal küçük harftir.
inline bool starts_with_i(const U16& s, std::size_t at, const char* literal) {
  std::size_t k = 0;
  for (; literal[k] != '\0'; ++k) {
    if (at + k >= s.size() || lower(s[at + k]) != static_cast<char16_t>(literal[k])) return false;
  }
  return true;
}

inline bool starts_with(const U16& s, std::size_t at, const char* literal) {
  std::size_t k = 0;
  for (; literal[k] != '\0'; ++k) {
    if (at + k >= s.size() || s[at + k] != static_cast<char16_t>(literal[k])) return false;
  }
  return true;
}

inline std::size_t literal_length(const char* literal) {
  std::size_t n = 0;
  while (literal[n] != '\0') ++n;
  return n;
}

// \b: konumun iki yanından biri kelime karakteri, diğeri değil.
inline bool boundary(const U16& s, std::size_t pos) {
  const bool before = pos > 0 && is_word(s[pos - 1]);
  const bool after = pos < s.size() && is_word(s[pos]);
  return before != after;
}

inline U16 lit(const char* literal) {
  U16 out;
  for (std::size_t k = 0; literal[k] != '\0'; ++k) out.push_back(static_cast<char16_t>(literal[k]));
  return out;
}

// Genel yürütücü: match(s, i) eşleşme bitişini (i'den büyük) ya da npos döndürür; replace(s, begin, end) yerine yazılacak metni verir.
constexpr std::size_t npos = static_cast<std::size_t>(-1);

template <typename Match, typename Replace>
U16 replace_all(const U16& s, Match match, Replace replace) {
  U16 out;
  out.reserve(s.size());
  std::size_t i = 0;
  while (i < s.size()) {
    const std::size_t end = match(s, i);
    if (end == npos || end <= i) {
      out.push_back(s[i]);
      ++i;
      continue;
    }
    out += replace(s, i, end);
    i = end;
  }
  return out;
}

// ---------------------------------------------------------------- adımlar (ErrorSanitizer.Scrub sırası)

// (https?://[^\s?#"'<>]+)[?#][^\s"'<>]*  ->  $1?[redacted]   (harfe duyarsız)
inline std::size_t match_url_query(const U16& s, std::size_t i, std::size_t& group_end) {
  if (!starts_with_i(s, i, "http")) return npos;
  std::size_t p = i + 4;
  if (p < s.size() && lower(s[p]) == u's') ++p;
  if (!starts_with(s, p, "://")) {
    if (p == i + 5) {
      p = i + 4;
      if (!starts_with(s, p, "://")) return npos;
    } else {
      return npos;
    }
  }
  p += 3;
  const std::size_t body = p;
  while (p < s.size()) {
    const char16_t c = s[p];
    if (is_space(c) || c == u'?' || c == u'#' || c == u'"' || c == u'\'' || c == u'<' || c == u'>') break;
    ++p;
  }
  if (p == body || p >= s.size() || (s[p] != u'?' && s[p] != u'#')) return npos;
  group_end = p;
  ++p;
  while (p < s.size()) {
    const char16_t c = s[p];
    if (is_space(c) || c == u'"' || c == u'\'' || c == u'<' || c == u'>') break;
    ++p;
  }
  return p;
}

inline bool jwt_class(char16_t c) { return is_alpha(c) || is_digit(c) || c == u'_' || c == u'-'; }

// eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]*
inline std::size_t match_jwt(const U16& s, std::size_t i) {
  if (!starts_with(s, i, "eyJ")) return npos;
  std::size_t p = i + 3;
  std::size_t run = p;
  while (p < s.size() && jwt_class(s[p])) ++p;
  if (p - run < 4 || p >= s.size() || s[p] != u'.') return npos;
  ++p;
  run = p;
  while (p < s.size() && jwt_class(s[p])) ++p;
  if (p - run < 4 || p >= s.size() || s[p] != u'.') return npos;
  ++p;
  while (p < s.size() && jwt_class(s[p])) ++p;
  return p;
}

// \b(password|passwd|pwd|secret|token|api[_\-]?key|authorization)\b\s*[=:]\s*[^\s,;"']+   (harfe duyarsız)
inline std::size_t match_secret(const U16& s, std::size_t i, std::size_t& key_end) {
  if (i > 0 && is_word(s[i - 1])) return npos;
  if (i >= s.size() || !is_word(s[i])) return npos;
  static const char* const words[] = {"password", "passwd", "pwd", "secret", "token", "authorization"};
  // api[_\-]?key ayrı aday: üç biçimi sırayla denenir.
  std::vector<std::size_t> ends;
  for (std::size_t w = 0; w < 4; ++w) {
    if (starts_with_i(s, i, words[w])) ends.push_back(i + literal_length(words[w]));
  }
  if (starts_with_i(s, i, "token")) ends.push_back(i + 5);
  if (starts_with_i(s, i, "api")) {
    std::size_t p = i + 3;
    if (p < s.size() && (s[p] == u'_' || s[p] == u'-') && starts_with_i(s, p + 1, "key")) ends.push_back(p + 4);
    if (starts_with_i(s, p, "key")) ends.push_back(p + 3);
  }
  if (starts_with_i(s, i, "authorization")) ends.push_back(i + 13);
  for (const std::size_t word_end : ends) {
    if (!(word_end > 0 && word_end <= s.size() && is_word(s[word_end - 1]))) continue;
    if (word_end < s.size() && is_word(s[word_end])) continue;
    std::size_t p = word_end;
    while (p < s.size() && is_space(s[p])) ++p;
    if (p >= s.size() || (s[p] != u'=' && s[p] != u':')) continue;
    ++p;
    while (p < s.size() && is_space(s[p])) ++p;
    const std::size_t value = p;
    while (p < s.size()) {
      const char16_t c = s[p];
      if (is_space(c) || c == u',' || c == u';' || c == u'"' || c == u'\'') break;
      ++p;
    }
    if (p == value) continue;
    key_end = word_end;
    return p;
  }
  return npos;
}

// \bbearer\s+[A-Za-z0-9._~+/=\-]+   (harfe duyarsız)
inline std::size_t match_bearer(const U16& s, std::size_t i) {
  if (i > 0 && is_word(s[i - 1])) return npos;
  if (!starts_with_i(s, i, "bearer")) return npos;
  std::size_t p = i + 6;
  const std::size_t spaces = p;
  while (p < s.size() && is_space(s[p])) ++p;
  if (p == spaces) return npos;
  const std::size_t run = p;
  while (p < s.size()) {
    const char16_t c = s[p];
    if (is_alpha(c) || is_digit(c) || c == u'.' || c == u'_' || c == u'~' || c == u'+' || c == u'/' || c == u'=' || c == u'-') {
      ++p;
    } else {
      break;
    }
  }
  return p == run ? npos : p;
}

inline bool email_local(char16_t c) { return is_alpha(c) || is_digit(c) || c == u'.' || c == u'_' || c == u'%' || c == u'+' || c == u'-'; }
inline bool email_domain(char16_t c) { return is_alpha(c) || is_digit(c) || c == u'.' || c == u'-'; }

// Alan adındaki son '.' sonrasında en az iki harf bulunan en uzun biçim (regex geri izlemesiyle aynı).
inline std::size_t match_email_domain(const U16& s, std::size_t at_pos) {
  const std::size_t start = at_pos + 1;
  std::size_t run_end = start;
  while (run_end < s.size() && email_domain(s[run_end])) ++run_end;
  for (std::size_t j = run_end; j-- > start + 1;) {
    if (s[j] != u'.') continue;
    std::size_t letters = j + 1;
    while (letters < s.size() && is_alpha(s[letters])) ++letters;
    if (letters - (j + 1) >= 2) return letters;
  }
  return npos;
}

inline U16 scrub_emails(const U16& s) {
  U16 out;
  std::size_t i = 0;
  while (i < s.size()) {
    if (!email_local(s[i])) {
      out.push_back(s[i++]);
      continue;
    }
    std::size_t run_end = i;
    while (run_end < s.size() && email_local(s[run_end])) ++run_end;
    if (run_end < s.size() && s[run_end] == u'@') {
      const std::size_t end = match_email_domain(s, run_end);
      if (end != npos) {
        out += lit("[email]");
        i = end;
        continue;
      }
    }
    out.append(s, i, run_end - i);
    i = run_end;
  }
  return out;
}

// ([A-Za-z]:\\Users\\)[^\\\s]+  ->  $1[user]   (harfe duyarsız)
inline std::size_t match_windows_user(const U16& s, std::size_t i, std::size_t& group_end) {
  if (!is_alpha(s[i]) || i + 1 >= s.size() || s[i + 1] != u':' || i + 2 >= s.size() || s[i + 2] != u'\\') return npos;
  if (!starts_with_i(s, i + 3, "users")) return npos;
  std::size_t p = i + 8;
  if (p >= s.size() || s[p] != u'\\') return npos;
  ++p;
  group_end = p;
  const std::size_t name = p;
  while (p < s.size() && s[p] != u'\\' && !is_space(s[p])) ++p;
  return p == name ? npos : p;
}

// (/(?:Users|home)/)[^/\s]+  ->  $1[user]   (harfe duyarlı)
inline std::size_t match_unix_user(const U16& s, std::size_t i, std::size_t& group_end) {
  if (s[i] != u'/') return npos;
  std::size_t p;
  if (starts_with(s, i + 1, "Users/")) {
    p = i + 7;
  } else if (starts_with(s, i + 1, "home/")) {
    p = i + 6;
  } else {
    return npos;
  }
  group_end = p;
  const std::size_t name = p;
  while (p < s.size() && s[p] != u'/' && !is_space(s[p])) ++p;
  return p == name ? npos : p;
}

// \b(?:\d{1,3}\.){3}\d{1,3}\b
inline std::size_t match_ipv4(const U16& s, std::size_t i) {
  if (!is_digit(s[i]) || !boundary(s, i)) return npos;
  std::size_t p = i;
  for (int group = 0; group < 3; ++group) {
    const std::size_t begin = p;
    while (p < s.size() && is_digit(s[p])) ++p;
    if (p == begin || p - begin > 3 || p >= s.size() || s[p] != u'.') return npos;
    ++p;
  }
  const std::size_t begin = p;
  while (p < s.size() && is_digit(s[p])) ++p;
  if (p == begin || p - begin > 3 || !boundary(s, p)) return npos;
  return p;
}

inline std::size_t ipv6_rest(const U16& s, std::size_t pos, int count) {
  std::size_t hexrun = 0;
  while (pos + hexrun < s.size() && is_hex(s[pos + hexrun])) ++hexrun;
  const std::size_t most = hexrun < 4 ? hexrun : 4;
  if (count < 7) {
    for (std::size_t len = most; len >= 1; --len) {
      if (pos + len < s.size() && s[pos + len] == u':') {
        const std::size_t r = ipv6_rest(s, pos + len + 1, count + 1);
        if (r != npos) return r;
      }
    }
  }
  if (count >= 3) {
    for (std::size_t len = most; len >= 1; --len) {
      if (boundary(s, pos + len)) return pos + len;
    }
  }
  return npos;
}

// \b(?:[0-9a-fA-F]{1,4}:){3,7}[0-9a-fA-F]{1,4}\b
inline std::size_t match_ipv6(const U16& s, std::size_t i) {
  if (!is_hex(s[i]) || !boundary(s, i)) return npos;
  return ipv6_rest(s, i, 0);
}

// \b[CLASS]{min,}\b : geri izlemeli en uzun eşleşme.
template <typename Class>
std::size_t match_run(const U16& s, std::size_t i, std::size_t min_length, Class in_class) {
  if (!in_class(s[i]) || !boundary(s, i)) return npos;
  std::size_t run_end = i;
  while (run_end < s.size() && in_class(s[run_end])) ++run_end;
  for (std::size_t end = run_end; end >= i + min_length; --end) {
    if (boundary(s, end)) return end;
    if (end == 0) break;
  }
  return npos;
}

inline bool phone_class(char16_t c) { return is_digit(c) || is_space(c) || c == u'(' || c == u')' || c == u'.' || c == u'-'; }

// \+?\d[\d\s().\-]{8,}\d
inline std::size_t match_phone(const U16& s, std::size_t i) {
  std::size_t p = s[i] == u'+' ? i + 1 : i;
  if (p >= s.size() || !is_digit(s[p])) return npos;
  const std::size_t first = p + 1;
  std::size_t run_end = first;
  while (run_end < s.size() && phone_class(s[run_end])) ++run_end;
  for (std::size_t pos = run_end; pos-- > first + 8;) {
    if (is_digit(s[pos])) return pos + 1;
  }
  return npos;
}

// Kişisel veri ve gizli değer ayıklanmış, sınırlandırılmış metin (ErrorSanitizer.Scrub). max_length UTF-16 kod birimidir.
inline std::string scrub(const std::string& text, std::size_t max_length) {
  if (text.empty()) return std::string();
  U16 s = to_u16(text);
  if (s.size() > max_length * 4) s.resize(max_length * 4);
  s = replace_all(
      s,
      [](const U16& v, std::size_t i) {
        std::size_t group_end = 0;
        return match_url_query(v, i, group_end);
      },
      [](const U16& v, std::size_t begin, std::size_t) {
        std::size_t group_end = 0;
        match_url_query(v, begin, group_end);
        U16 out = v.substr(begin, group_end - begin);
        out += lit("?[redacted]");
        return out;
      });
  s = replace_all(s, match_jwt, [](const U16&, std::size_t, std::size_t) { return lit("[token]"); });
  s = replace_all(
      s,
      [](const U16& v, std::size_t i) {
        std::size_t key_end = 0;
        return match_secret(v, i, key_end);
      },
      [](const U16& v, std::size_t begin, std::size_t) {
        std::size_t key_end = 0;
        match_secret(v, begin, key_end);
        U16 out = v.substr(begin, key_end - begin);
        out += lit("=[redacted]");
        return out;
      });
  s = replace_all(s, match_bearer, [](const U16&, std::size_t, std::size_t) { return lit("Bearer [token]"); });
  s = scrub_emails(s);
  s = replace_all(
      s,
      [](const U16& v, std::size_t i) {
        std::size_t group_end = 0;
        return match_windows_user(v, i, group_end);
      },
      [](const U16& v, std::size_t begin, std::size_t) {
        std::size_t group_end = 0;
        match_windows_user(v, begin, group_end);
        U16 out = v.substr(begin, group_end - begin);
        out += lit("[user]");
        return out;
      });
  s = replace_all(
      s,
      [](const U16& v, std::size_t i) {
        std::size_t group_end = 0;
        return match_unix_user(v, i, group_end);
      },
      [](const U16& v, std::size_t begin, std::size_t) {
        std::size_t group_end = 0;
        match_unix_user(v, begin, group_end);
        U16 out = v.substr(begin, group_end - begin);
        out += lit("[user]");
        return out;
      });
  s = replace_all(s, match_ipv4, [](const U16&, std::size_t, std::size_t) { return lit("[ip]"); });
  s = replace_all(s, match_ipv6, [](const U16&, std::size_t, std::size_t) { return lit("[ip]"); });
  s = replace_all(s, [](const U16& v, std::size_t i) { return match_run(v, i, 32, is_hex); }, [](const U16&, std::size_t, std::size_t) { return lit("[token]"); });
  s = replace_all(
      s, [](const U16& v, std::size_t i) { return match_run(v, i, 40, jwt_class); }, [](const U16&, std::size_t, std::size_t) { return lit("[token]"); });
  s = replace_all(s, match_phone, [](const U16&, std::size_t, std::size_t) { return lit("[number]"); });
  for (char16_t& c : s) {
    if (c == u'\r' || c == u'\n') c = u' ';
  }
  std::size_t begin = 0;
  std::size_t end = s.size();
  while (begin < end && is_space(s[begin])) ++begin;
  while (end > begin && is_space(s[end - 1])) --end;
  s = s.substr(begin, end - begin);
  if (s.size() > max_length) s.resize(max_length);
  return to_utf8(s);
}

// ---------------------------------------------------------------- yığın çerçeveleri

// \s*\(at [^)]*\) | \s+in\s+<[^>]*>:\d+ | \s+in\s+\S+:\d+ | \s*\[0x[0-9a-fA-F]+\] | \s+\[at [^\]]*\]
inline std::size_t match_frame_location(const U16& s, std::size_t i) {
  std::size_t ws = i;
  while (ws < s.size() && is_space(s[ws])) ++ws;
  const bool has_space = ws > i;
  // 1: \s*\(at [^)]*\)
  if (starts_with(s, ws, "(at ")) {
    std::size_t p = ws + 4;
    while (p < s.size() && s[p] != u')') ++p;
    if (p < s.size()) return p + 1;
  }
  if (has_space && starts_with(s, ws, "in")) {
    std::size_t p = ws + 2;
    const std::size_t after_in = p;
    while (p < s.size() && is_space(s[p])) ++p;
    if (p > after_in) {
      // 2: <...>:\d+
      if (p < s.size() && s[p] == u'<') {
        std::size_t q = p + 1;
        while (q < s.size() && s[q] != u'>') ++q;
        if (q < s.size() && q + 1 < s.size() && s[q + 1] == u':') {
          std::size_t d = q + 2;
          const std::size_t digits = d;
          while (d < s.size() && is_digit(s[d])) ++d;
          if (d > digits) return d;
        }
      }
      // 3: \S+:\d+ (en uzun \S+ ile geri izleme)
      std::size_t run_end = p;
      while (run_end < s.size() && !is_space(s[run_end])) ++run_end;
      for (std::size_t colon = run_end; colon-- > p + 1;) {
        if (s[colon] == u':' && colon + 1 < run_end && is_digit(s[colon + 1])) {
          std::size_t d = colon + 1;
          while (d < s.size() && is_digit(s[d])) ++d;
          return d;
        }
      }
    }
  }
  // 4: \s*\[0x[0-9a-fA-F]+\]
  if (starts_with(s, ws, "[0x")) {
    std::size_t p = ws + 3;
    const std::size_t digits = p;
    while (p < s.size() && is_hex(s[p])) ++p;
    if (p > digits && p < s.size() && s[p] == u']') return p + 1;
  }
  // 5: \s+\[at [^\]]*\]
  if (has_space && starts_with(s, ws, "[at ")) {
    std::size_t p = ws + 4;
    while (p < s.size() && s[p] != u']') ++p;
    if (p < s.size()) return p + 1;
  }
  return npos;
}

inline std::string normalize_one_frame(const std::string& raw_line) {
  U16 line = to_u16(raw_line);
  line = replace_all(line, match_frame_location, [](const U16&, std::size_t, std::size_t) { return U16(); });
  // ^\s*(?:at\s+)?
  std::size_t p = 0;
  while (p < line.size() && is_space(line[p])) ++p;
  if (starts_with(line, p, "at")) {
    std::size_t q = p + 2;
    const std::size_t spaces = q;
    while (q < line.size() && is_space(line[q])) ++q;
    if (q > spaces) p = q;
  }
  line = line.substr(p);
  // \([^()]*\) en çok üç tur
  for (int round = 0; round < 3; ++round) {
    U16 next;
    std::size_t i = 0;
    bool changed = false;
    while (i < line.size()) {
      if (line[i] == u'(') {
        std::size_t j = i + 1;
        while (j < line.size() && line[j] != u'(' && line[j] != u')') ++j;
        if (j < line.size() && line[j] == u')') {
          i = j + 1;
          changed = true;
          continue;
        }
      }
      next.push_back(line[i++]);
    }
    line = next;
    if (!changed) break;
  }
  // 0x[0-9a-fA-F]+ -> 0x ; \d+ -> #
  U16 hexed;
  for (std::size_t i = 0; i < line.size();) {
    if (starts_with(line, i, "0x") && i + 2 < line.size() && is_hex(line[i + 2])) {
      std::size_t j = i + 2;
      while (j < line.size() && is_hex(line[j])) ++j;
      hexed += lit("0x");
      i = j;
    } else {
      hexed.push_back(line[i++]);
    }
  }
  U16 digits;
  for (std::size_t i = 0; i < hexed.size();) {
    if (is_digit(hexed[i])) {
      while (i < hexed.size() && is_digit(hexed[i])) ++i;
      digits.push_back(u'#');
    } else {
      digits.push_back(hexed[i++]);
    }
  }
  return scrub(to_utf8(digits), 200);
}

// Yığın izini normalleştirilmiş çerçeve listesine çevirir (dosya yolu, satır, adres ve bağımsız değişken yok).
inline std::vector<std::string> normalize_frames(const std::string& stack_trace, std::size_t max_frames) {
  std::vector<std::string> frames;
  if (stack_trace.empty()) return frames;
  std::size_t start = 0;
  while (start <= stack_trace.size()) {
    std::size_t end = stack_trace.find('\n', start);
    if (end == std::string::npos) end = stack_trace.size();
    std::string line = stack_trace.substr(start, end - start);
    start = end + 1;
    std::size_t b = 0;
    std::size_t e = line.size();
    while (b < e && (line[b] == '\r' || line[b] == ' ' || line[b] == '\t')) ++b;
    while (e > b && (line[e - 1] == '\r' || line[e - 1] == ' ' || line[e - 1] == '\t')) --e;
    line = line.substr(b, e - b);
    if (line.empty()) continue;
    const std::string normalized = normalize_one_frame(line);
    if (normalized.empty()) continue;
    frames.push_back(normalized);
    if (frames.size() >= max_frames) break;
  }
  return frames;
}

// Hata türü ve ilk altı normalleştirilmiş çerçevenin SHA-256 özetinin ilk 16 onaltılık karakteri.
inline std::string fingerprint(const std::string& error_type, const std::vector<std::string>& frames) {
  std::string input = error_type;
  for (std::size_t i = 0; i < frames.size() && i < 6; ++i) {
    input.push_back('\n');
    input += frames[i];
  }
  const std::string hex = crypto::sha256_hex(input);
  return hex.substr(0, 16);
}

}  // namespace sanitize
}  // namespace feralin

#endif  // FERALIN_SANITIZE_HPP
