// Kalıcı kuyruk için AES-256-GCM, şifreli olay deposu ve anahtar sağlayıcı. Yalnız standart kütüphane.
//
// Satır biçimi Android EncryptedEventStore ve Unity ile aynıdır: events.log her satırda "kimlik TAB enc1:" + hex(iv(12) || şifreli metin || etiket(16)),
// ilişkilendirilmiş veri (AAD) olay kimliğidir. Açılamayan satır kuyruktan atılır; anahtar alınamazsa düz metne düşülmez, kuyruk bellekte kalır.
#ifndef FERALIN_CRYPTO_HPP
#define FERALIN_CRYPTO_HPP

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

namespace feralin {
namespace crypto {

using Bytes = std::vector<std::uint8_t>;

namespace detail {

inline const std::uint8_t* sbox() {
  static std::uint8_t table[256];
  static bool ready = false;
  if (!ready) {
    // Rijndael S-kutusu: GF(2^8) tersi + afin dönüşüm.
    std::uint8_t p = 1, q = 1;
    do {
      p = static_cast<std::uint8_t>(p ^ (p << 1) ^ ((p & 0x80u) ? 0x1Bu : 0u));
      q = static_cast<std::uint8_t>(q ^ (q << 1));
      q = static_cast<std::uint8_t>(q ^ (q << 2));
      q = static_cast<std::uint8_t>(q ^ (q << 4));
      if (q & 0x80u) q = static_cast<std::uint8_t>(q ^ 0x09u);
      const auto rotl = [](std::uint8_t v, unsigned n) { return static_cast<std::uint8_t>((v << n) | (v >> (8u - n))); };
      table[p] = static_cast<std::uint8_t>(q ^ rotl(q, 1) ^ rotl(q, 2) ^ rotl(q, 3) ^ rotl(q, 4) ^ 0x63u);
    } while (p != 1);
    table[0] = 0x63;
    ready = true;
  }
  return table;
}

inline std::uint8_t xtime(std::uint8_t v) { return static_cast<std::uint8_t>((v << 1) ^ ((v & 0x80u) ? 0x1Bu : 0u)); }

}  // namespace detail

// AES-256 tek blok şifreleme.
class Aes256 {
 public:
  explicit Aes256(const std::uint8_t* key) {
    const std::uint8_t* s = detail::sbox();
    for (std::size_t i = 0; i < 32; ++i) round_keys_[i] = key[i];
    std::uint8_t rcon = 1;
    for (std::size_t i = 32; i < 240; i += 4) {
      std::uint8_t t[4] = {round_keys_[i - 4], round_keys_[i - 3], round_keys_[i - 2], round_keys_[i - 1]};
      if (i % 32 == 0) {
        const std::uint8_t first = t[0];
        t[0] = static_cast<std::uint8_t>(s[t[1]] ^ rcon);
        t[1] = s[t[2]];
        t[2] = s[t[3]];
        t[3] = s[first];
        rcon = detail::xtime(rcon);
      } else if (i % 32 == 16) {
        for (auto& b : t) b = s[b];
      }
      for (std::size_t b = 0; b < 4; ++b) round_keys_[i + b] = static_cast<std::uint8_t>(round_keys_[i - 32 + b] ^ t[b]);
    }
  }

  void encrypt(const std::uint8_t* in, std::uint8_t* out) const {
    const std::uint8_t* s = detail::sbox();
    std::uint8_t st[16];
    for (std::size_t i = 0; i < 16; ++i) st[i] = static_cast<std::uint8_t>(in[i] ^ round_keys_[i]);
    for (std::size_t round = 1; round <= 14; ++round) {
      std::uint8_t t[16];
      for (std::size_t i = 0; i < 16; ++i) t[i] = s[st[i]];
      // ShiftRows (sütun öncelikli düzen)
      std::uint8_t r[16] = {t[0], t[5], t[10], t[15], t[4], t[9], t[14], t[3], t[8], t[13], t[2], t[7], t[12], t[1], t[6], t[11]};
      if (round != 14) {
        for (std::size_t c = 0; c < 4; ++c) {
          const std::uint8_t a0 = r[c * 4], a1 = r[c * 4 + 1], a2 = r[c * 4 + 2], a3 = r[c * 4 + 3];
          const std::uint8_t all = static_cast<std::uint8_t>(a0 ^ a1 ^ a2 ^ a3);
          st[c * 4] = static_cast<std::uint8_t>(a0 ^ all ^ detail::xtime(static_cast<std::uint8_t>(a0 ^ a1)));
          st[c * 4 + 1] = static_cast<std::uint8_t>(a1 ^ all ^ detail::xtime(static_cast<std::uint8_t>(a1 ^ a2)));
          st[c * 4 + 2] = static_cast<std::uint8_t>(a2 ^ all ^ detail::xtime(static_cast<std::uint8_t>(a2 ^ a3)));
          st[c * 4 + 3] = static_cast<std::uint8_t>(a3 ^ all ^ detail::xtime(static_cast<std::uint8_t>(a3 ^ a0)));
        }
      } else {
        for (std::size_t i = 0; i < 16; ++i) st[i] = r[i];
      }
      for (std::size_t i = 0; i < 16; ++i) st[i] = static_cast<std::uint8_t>(st[i] ^ round_keys_[round * 16 + i]);
    }
    for (std::size_t i = 0; i < 16; ++i) out[i] = st[i];
  }

 private:
  std::uint8_t round_keys_[240];
};

constexpr std::size_t kIvBytes = 12;
constexpr std::size_t kTagBytes = 16;

namespace detail {

struct Block {
  std::uint64_t hi = 0, lo = 0;
};

inline Block load_block(const std::uint8_t* p) {
  Block b;
  for (std::size_t i = 0; i < 8; ++i) b.hi = (b.hi << 8) | p[i];
  for (std::size_t i = 8; i < 16; ++i) b.lo = (b.lo << 8) | p[i];
  return b;
}

// GF(2^128) çarpımı (NIST SP 800-38D algoritma 1).
inline Block gf_mul(Block x, Block y) {
  Block z;
  Block v = y;
  for (int i = 0; i < 128; ++i) {
    const bool bit = i < 64 ? ((x.hi >> (63 - i)) & 1u) != 0 : ((x.lo >> (127 - i)) & 1u) != 0;
    if (bit) {
      z.hi ^= v.hi;
      z.lo ^= v.lo;
    }
    const bool lsb = (v.lo & 1u) != 0;
    v.lo = (v.lo >> 1) | (v.hi << 63);
    v.hi >>= 1;
    if (lsb) v.hi ^= 0xE100000000000000ull;
  }
  return z;
}

class Ghash {
 public:
  explicit Ghash(Block h) : h_(h) {}
  void update(const std::uint8_t* data, std::size_t length) {
    for (std::size_t i = 0; i < length; i += 16) {
      std::uint8_t block[16] = {0};
      const std::size_t n = std::min<std::size_t>(16, length - i);
      for (std::size_t k = 0; k < n; ++k) block[k] = data[i + k];
      const Block b = load_block(block);
      y_.hi ^= b.hi;
      y_.lo ^= b.lo;
      y_ = gf_mul(y_, h_);
    }
  }
  Block finish(std::uint64_t aad_bits, std::uint64_t text_bits) {
    y_.hi ^= aad_bits;
    y_.lo ^= text_bits;
    return gf_mul(y_, h_);
  }

 private:
  Block h_;
  Block y_;
};

inline void ctr_xor(const Aes256& aes, const std::uint8_t* iv, std::uint32_t first_counter, const std::uint8_t* in, std::size_t length, std::uint8_t* out) {
  std::uint8_t counter[16];
  for (std::size_t i = 0; i < 12; ++i) counter[i] = iv[i];
  std::uint32_t c = first_counter;
  for (std::size_t i = 0; i < length; i += 16) {
    counter[12] = static_cast<std::uint8_t>(c >> 24);
    counter[13] = static_cast<std::uint8_t>(c >> 16);
    counter[14] = static_cast<std::uint8_t>(c >> 8);
    counter[15] = static_cast<std::uint8_t>(c);
    ++c;
    std::uint8_t stream[16];
    aes.encrypt(counter, stream);
    const std::size_t n = std::min<std::size_t>(16, length - i);
    for (std::size_t k = 0; k < n; ++k) out[i + k] = static_cast<std::uint8_t>(in[i + k] ^ stream[k]);
  }
}

inline void tag_for(const Aes256& aes, const std::uint8_t* iv, const std::uint8_t* aad, std::size_t aad_len, const std::uint8_t* cipher, std::size_t cipher_len, std::uint8_t* tag) {
  const std::uint8_t zero[16] = {0};
  std::uint8_t hblock[16];
  aes.encrypt(zero, hblock);
  Ghash ghash(load_block(hblock));
  ghash.update(aad, aad_len);
  ghash.update(cipher, cipher_len);
  const Block s = ghash.finish(static_cast<std::uint64_t>(aad_len) * 8u, static_cast<std::uint64_t>(cipher_len) * 8u);
  std::uint8_t mask[16];
  ctr_xor(aes, iv, 1, zero, 16, mask);
  for (std::size_t i = 0; i < 8; ++i) tag[i] = static_cast<std::uint8_t>(((s.hi >> (56 - 8 * i)) & 0xFFu) ^ mask[i]);
  for (std::size_t i = 0; i < 8; ++i) tag[8 + i] = static_cast<std::uint8_t>(((s.lo >> (56 - 8 * i)) & 0xFFu) ^ mask[8 + i]);
}

}  // namespace detail

// Çıktı: şifreli metin || 16 baytlık etiket.
inline Bytes gcm_seal(const std::uint8_t* key, const std::uint8_t* iv, const Bytes& plain, const Bytes& aad) {
  const Aes256 aes(key);
  Bytes out(plain.size() + kTagBytes);
  detail::ctr_xor(aes, iv, 2, plain.data(), plain.size(), out.data());
  detail::tag_for(aes, iv, aad.data(), aad.size(), out.data(), plain.size(), out.data() + plain.size());
  return out;
}

// Etiket tutmazsa boş ve false.
inline bool gcm_open(const std::uint8_t* key, const std::uint8_t* iv, const Bytes& sealed, const Bytes& aad, Bytes& plain) {
  if (sealed.size() < kTagBytes) return false;
  const Aes256 aes(key);
  const std::size_t length = sealed.size() - kTagBytes;
  std::uint8_t tag[16];
  detail::tag_for(aes, iv, aad.data(), aad.size(), sealed.data(), length, tag);
  std::uint8_t diff = 0;
  for (std::size_t i = 0; i < 16; ++i) diff = static_cast<std::uint8_t>(diff | (tag[i] ^ sealed[length + i]));
  if (diff != 0) return false;
  plain.assign(length, 0);
  detail::ctr_xor(aes, iv, 2, sealed.data(), length, plain.data());
  return true;
}

inline std::string hex_encode(const Bytes& bytes) {
  static const char digits[] = "0123456789abcdef";
  std::string out;
  out.reserve(bytes.size() * 2);
  for (const std::uint8_t b : bytes) {
    out.push_back(digits[b >> 4]);
    out.push_back(digits[b & 0xF]);
  }
  return out;
}

inline int hex_value(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

inline bool hex_decode(const std::string& text, Bytes& out) {
  if (text.size() % 2 != 0) return false;
  out.clear();
  for (std::size_t i = 0; i < text.size(); i += 2) {
    const int hi = hex_value(text[i]);
    const int lo = hex_value(text[i + 1]);
    if (hi < 0 || lo < 0) return false;
    out.push_back(static_cast<std::uint8_t>((hi << 4) | lo));
  }
  return true;
}

using IvSource = std::function<Bytes()>;

// enc1: + hex(iv || şifreli metin || etiket). Anahtar 32 bayt olmalı.
class AesGcmPayloadCipher {
 public:
  static constexpr const char* kPrefix = "enc1:";

  AesGcmPayloadCipher(Bytes key, IvSource iv_source) : key_(std::move(key)), iv_(std::move(iv_source)) {}
  bool valid() const { return key_.size() == 32; }

  std::string encrypt(const std::string& plain, const std::string& aad) const {
    const Bytes iv = iv_();
    const Bytes sealed = gcm_seal(key_.data(), iv.data(), Bytes(plain.begin(), plain.end()), Bytes(aad.begin(), aad.end()));
    Bytes all = iv;
    all.insert(all.end(), sealed.begin(), sealed.end());
    return std::string(kPrefix) + hex_encode(all);
  }

  // Açılamazsa (bozuk, kurcalanmış, anahtar kayıp, düz metin) false.
  bool decrypt(const std::string& stored, const std::string& aad, std::string& plain) const {
    if (stored.rfind(kPrefix, 0) != 0) return false;
    Bytes raw;
    if (!hex_decode(stored.substr(5), raw) || raw.size() <= kIvBytes + kTagBytes) return false;
    const Bytes sealed(raw.begin() + static_cast<std::ptrdiff_t>(kIvBytes), raw.end());
    Bytes out;
    if (!gcm_open(key_.data(), raw.data(), sealed, Bytes(aad.begin(), aad.end()), out)) return false;
    plain.assign(out.begin(), out.end());
    return true;
  }

 private:
  Bytes key_;
  IvSource iv_;
};

struct StoredEvent {
  std::string id;
  std::string payload;
};

// Kalıcı olay kuyruğu ve küçük işaret deposu. Çağrılar oyuna hata fırlatmaz.
class EventStore {
 public:
  virtual ~EventStore() = default;
  virtual std::vector<StoredEvent> load() = 0;
  virtual void add(const StoredEvent& item) = 0;
  virtual void remove(const std::set<std::string>& ids) = 0;
  virtual void clear() = 0;
  virtual bool get_marker(const std::string& key, std::string& value) = 0;
  virtual void put_marker(const std::string& key, const std::string& value) = 0;
  virtual void remove_marker(const std::string& key) = 0;
};

// Dosya tabanlı depo (events.log, markers.log). Ekleme dosya sonuna yazar; silme geçici dosya üzerinden yeniden yazar.
// Yarım kalmış son satır sonraki eklemede tamamlanır; geçersiz satır yok sayılır. G/Ç hatası failures()'ı artırır.
class FileEventStore : public EventStore {
 public:
  explicit FileEventStore(std::string directory) : dir_(std::move(directory)) {
    if (!dir_.empty() && dir_.back() != '/' && dir_.back() != '\\') dir_.push_back('/');
  }
  int failures() const { return failures_; }

  std::vector<StoredEvent> load() override {
    std::vector<StoredEvent> list;
    std::set<std::string> seen;
    for (const std::string& line : read_lines(events_path_())) {
      const std::size_t tab = line.find('\t');
      if (tab != 26 || line.size() <= 27) continue;
      std::string id = line.substr(0, tab);
      if (seen.insert(id).second) list.push_back(StoredEvent{id, line.substr(tab + 1)});
    }
    return list;
  }

  void add(const StoredEvent& item) override {
    if (item.id.size() != 26 || item.payload.find_first_of("\r\n") != std::string::npos) return;
    ensure_tail();
    std::FILE* f = std::fopen(events_path_().c_str(), "ab");
    if (f == nullptr) {
      ++failures_;
      return;
    }
    const std::string line = item.id + "\t" + item.payload + "\n";
    if (std::fwrite(line.data(), 1, line.size(), f) != line.size()) ++failures_;
    std::fclose(f);
  }

  void remove(const std::set<std::string>& ids) override {
    if (ids.empty()) return;
    std::vector<std::string> keep;
    for (const std::string& line : read_lines(events_path_())) {
      const std::size_t tab = line.find('\t');
      if (tab == 26 && ids.count(line.substr(0, tab)) == 0) keep.push_back(line);
    }
    rewrite(events_path_(), keep);
    tail_checked_ = true;
  }

  void clear() override {
    std::remove(events_path_().c_str());
    tail_checked_ = true;
  }

  bool get_marker(const std::string& key, std::string& value) override {
    const auto map = read_markers();
    const auto it = map.find(key);
    if (it == map.end()) return false;
    value = it->second;
    return true;
  }

  void put_marker(const std::string& key, const std::string& value) override {
    if (key.empty() || key.find_first_of("\t\r\n") != std::string::npos || value.find_first_of("\r\n") != std::string::npos) return;
    auto map = read_markers();
    map[key] = value;
    write_markers(map);
  }

  void remove_marker(const std::string& key) override {
    auto map = read_markers();
    if (map.erase(key) > 0) write_markers(map);
  }

 private:
  std::string events_path_() const { return dir_ + "events.log"; }
  std::string markers_path_() const { return dir_ + "markers.log"; }

  std::vector<std::string> read_lines(const std::string& path) {
    std::vector<std::string> lines;
    std::FILE* f = std::fopen(path.c_str(), "rb");
    if (f == nullptr) return lines;
    std::string text;
    char buffer[4096];
    std::size_t n;
    while ((n = std::fread(buffer, 1, sizeof(buffer), f)) > 0) text.append(buffer, n);
    std::fclose(f);
    std::size_t start = 0;
    while (start < text.size()) {
      std::size_t end = text.find('\n', start);
      if (end == std::string::npos) end = text.size();
      std::string line = text.substr(start, end - start);
      while (!line.empty() && line.back() == '\r') line.pop_back();
      if (!line.empty()) lines.push_back(line);
      start = end + 1;
    }
    return lines;
  }

  void rewrite(const std::string& path, const std::vector<std::string>& lines) {
    if (lines.empty()) {
      std::remove(path.c_str());
      return;
    }
    const std::string temporary = path + ".tmp";
    std::FILE* f = std::fopen(temporary.c_str(), "wb");
    if (f == nullptr) {
      ++failures_;
      return;
    }
    for (const std::string& line : lines) {
      std::fwrite(line.data(), 1, line.size(), f);
      std::fputc('\n', f);
    }
    std::fclose(f);
    // rename hedef varsa Windows'ta başarısız olur: önce siler.
    std::remove(path.c_str());
    if (std::rename(temporary.c_str(), path.c_str()) != 0) ++failures_;
  }

  std::map<std::string, std::string> read_markers() {
    std::map<std::string, std::string> map;
    for (const std::string& line : read_lines(markers_path_())) {
      const std::size_t tab = line.find('\t');
      if (tab != std::string::npos && tab > 0) map[line.substr(0, tab)] = line.substr(tab + 1);
    }
    return map;
  }

  void write_markers(const std::map<std::string, std::string>& map) {
    std::vector<std::string> lines;
    for (const auto& pair : map) lines.push_back(pair.first + "\t" + pair.second);
    rewrite(markers_path_(), lines);
  }

  // Son bayt satır sonu değilse (yarım yazma) tamamlanır; sonraki geçerli olay bozuk satıra yapışmaz.
  void ensure_tail() {
    if (tail_checked_) return;
    tail_checked_ = true;
    std::FILE* f = std::fopen(events_path_().c_str(), "rb");
    if (f == nullptr) return;
    std::fseek(f, 0, SEEK_END);
    const long size = std::ftell(f);
    int last = '\n';
    if (size > 0) {
      std::fseek(f, size - 1, SEEK_SET);
      last = std::fgetc(f);
    }
    std::fclose(f);
    if (size > 0 && last != '\n') {
      std::FILE* w = std::fopen(events_path_().c_str(), "ab");
      if (w != nullptr) {
        std::fputc('\n', w);
        std::fclose(w);
      }
    }
  }

  std::string dir_;
  int failures_ = 0;
  bool tail_checked_ = false;
};

// Olay gövdelerini şifreleyen sarmalayıcı. Açılamayan satır kuyruktan atılır; işaretler olduğu gibi kalır.
class EncryptedEventStore : public EventStore {
 public:
  EncryptedEventStore(std::unique_ptr<EventStore> inner, AesGcmPayloadCipher cipher) : inner_(std::move(inner)), cipher_(std::move(cipher)) {}

  std::vector<StoredEvent> load() override {
    std::vector<StoredEvent> result;
    std::set<std::string> broken;
    for (const StoredEvent& row : inner_->load()) {
      std::string plain;
      if (cipher_.decrypt(row.payload, row.id, plain)) {
        result.push_back(StoredEvent{row.id, plain});
      } else {
        broken.insert(row.id);
      }
    }
    if (!broken.empty()) inner_->remove(broken);
    return result;
  }
  void add(const StoredEvent& item) override { inner_->add(StoredEvent{item.id, cipher_.encrypt(item.payload, item.id)}); }
  void remove(const std::set<std::string>& ids) override { inner_->remove(ids); }
  void clear() override { inner_->clear(); }
  bool get_marker(const std::string& key, std::string& value) override { return inner_->get_marker(key, value); }
  void put_marker(const std::string& key, const std::string& value) override { inner_->put_marker(key, value); }
  void remove_marker(const std::string& key) override { inner_->remove_marker(key); }

 private:
  std::unique_ptr<EventStore> inner_;
  AesGcmPayloadCipher cipher_;
};

// Kuyruk anahtarını sarar (Android Keystore, iOS Keychain). Başarısızsa boş döner.
class KeyProtector {
 public:
  virtual ~KeyProtector() = default;
  // android_keystore, ios_keychain ya da local_file (yalnız dosya izni; sarma yok).
  virtual std::string protection() const = 0;
  virtual Bytes protect(const Bytes& data) = 0;
  virtual Bytes unprotect(const Bytes& data) = 0;
};

class PlainKeyProtector : public KeyProtector {
 public:
  std::string protection() const override { return "local_file"; }
  Bytes protect(const Bytes& data) override { return data; }
  Bytes unprotect(const Bytes& data) override { return data; }
};

using RandomBytes = std::function<Bytes(std::size_t)>;

// 32 baytlık veri anahtarı queue.key dosyasında yalnız sarılmış hâlde durur. Alınamazsa boş (kuyruk bellekte kalır).
class WrappedFileKeyProvider {
 public:
  WrappedFileKeyProvider(std::string directory, std::shared_ptr<KeyProtector> protector, RandomBytes random)
      : path_(std::move(directory)), protector_(std::move(protector)), random_(std::move(random)) {
    if (!path_.empty() && path_.back() != '/' && path_.back() != '\\') path_.push_back('/');
    path_ += "queue.key";
  }
  std::string protection() const { return protector_->protection(); }

  Bytes get_or_create() {
    if (cached_.size() == 32) return cached_;
    if (std::FILE* f = std::fopen(path_.c_str(), "rb")) {
      Bytes wrapped;
      char buffer[256];
      std::size_t n;
      while ((n = std::fread(buffer, 1, sizeof(buffer), f)) > 0) wrapped.insert(wrapped.end(), buffer, buffer + n);
      std::fclose(f);
      const Bytes key = protector_->unprotect(wrapped);
      if (key.size() == 32) {
        cached_ = key;
        return cached_;
      }
      // Sarmalayıcı anahtarı açamıyor: eski satırlar zaten okunamaz, yeni anahtar üretilir.
    }
    const Bytes fresh = random_(32);
    if (fresh.size() != 32) return Bytes();
    const Bytes wrapped = protector_->protect(fresh);
    if (wrapped.empty()) return Bytes();
    std::FILE* w = std::fopen(path_.c_str(), "wb");
    if (w == nullptr) return Bytes();
    const bool ok = std::fwrite(wrapped.data(), 1, wrapped.size(), w) == wrapped.size();
    std::fclose(w);
    if (!ok) return Bytes();
    cached_ = fresh;
    return cached_;
  }

  void delete_key() {
    cached_.clear();
    std::remove(path_.c_str());
  }

 private:
  std::string path_;
  std::shared_ptr<KeyProtector> protector_;
  RandomBytes random_;
  Bytes cached_;
};

}  // namespace crypto
}  // namespace feralin

#endif  // FERALIN_CRYPTO_HPP
