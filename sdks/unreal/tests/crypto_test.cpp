// Sanitize, SHA-256, AES-GCM ve şifreli depo: NIST vektörleri ve Unity (referans) çıktılarıyla birebir karşılaştırma.
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>

#include "FeralinCrypto.hpp"
#include "FeralinSanitize.hpp"
#include "FeralinWire.hpp"

using feralin::wire::Value;
namespace crypto = feralin::crypto;
namespace sanitize = feralin::sanitize;

static int g_checks = 0, g_failures = 0;
#define CHECK_THAT(c) do { ++g_checks; if (!(c)) { ++g_failures; std::printf("KALDI %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

static crypto::Bytes hex(const std::string& text) {
  crypto::Bytes out;
  crypto::hex_decode(text, out);
  return out;
}

static std::string str(const Value* v) { return v != nullptr && v->is_string() ? v->as_string() : std::string("<yok>"); }

int main(int argc, char** argv) {
  const std::string dir = argc > 1 ? argv[1] : ".";
  // SHA-256 (FIPS 180-4)
  CHECK_THAT(crypto::sha256_hex("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
  CHECK_THAT(crypto::sha256_hex("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
  // AES-256-GCM NIST test case 13/14 (sıfır anahtar) ve 16 (AAD'sız dört blok).
  {
    const crypto::Bytes key(32, 0), iv(12, 0);
    const crypto::Bytes sealed = crypto::gcm_seal(key.data(), iv.data(), crypto::Bytes(16, 0), crypto::Bytes());
    CHECK_THAT(crypto::hex_encode(sealed) == "cea7403d4d606b6e074ec5d3baf39d18d0d1c8a799996bf0265b98b5d48ab919");
    const crypto::Bytes empty = crypto::gcm_seal(key.data(), iv.data(), crypto::Bytes(), crypto::Bytes());
    CHECK_THAT(crypto::hex_encode(empty) == "530f8afbc74536b9a963b4f1c4cb738b");
  }
  {
    const crypto::Bytes key = hex("feffe9928665731c6d6a8f9467308308feffe9928665731c6d6a8f9467308308");
    const crypto::Bytes iv = hex("cafebabefacedbaddecaf888");
    const crypto::Bytes pt = hex("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a721c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255");
    const crypto::Bytes sealed = crypto::gcm_seal(key.data(), iv.data(), pt, crypto::Bytes());
    CHECK_THAT(crypto::hex_encode(sealed) ==
               "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad"
               "b094dac5d93471bdec1a502270e3cc6c");
    crypto::Bytes back;
    CHECK_THAT(crypto::gcm_open(key.data(), iv.data(), sealed, crypto::Bytes(), back) && back == pt);
    crypto::Bytes tampered = sealed;
    tampered[3] ^= 1;
    CHECK_THAT(!crypto::gcm_open(key.data(), iv.data(), tampered, crypto::Bytes(), back));
  }

  Value vectors;
  CHECK_THAT(feralin::wire::parse_json(read_file(dir + "/vectors/sdk_vectors.json"), vectors));
  const Value* scrub = vectors.find("scrub");
  CHECK_THAT(scrub != nullptr && scrub->size() > 0);
  for (std::size_t i = 0; scrub != nullptr && i < scrub->size(); ++i) {
    const Value& c = scrub->at(i);
    const std::string actual = sanitize::scrub(str(c.find("in")), static_cast<std::size_t>(c.find("max")->as_int()));
    if (actual != str(c.find("out"))) std::printf("  scrub[%zu]\n    girdi   : %s\n    beklenen: %s\n    gelen   : %s\n", i, str(c.find("in")).c_str(), str(c.find("out")).c_str(), actual.c_str());
    CHECK_THAT(actual == str(c.find("out")));
  }
  const Value* frames = vectors.find("frames");
  for (std::size_t i = 0; frames != nullptr && i < frames->size(); ++i) {
    const Value& c = frames->at(i);
    const auto list = sanitize::normalize_frames(str(c.find("in")), static_cast<std::size_t>(c.find("max")->as_int()));
    const Value* expected = c.find("frames");
    bool same = expected != nullptr && list.size() == expected->size();
    for (std::size_t k = 0; same && k < list.size(); ++k) same = list[k] == expected->at(k).as_string();
    if (!same) {
      std::printf("  frames[%zu] girdi: %s\n", i, str(c.find("in")).c_str());
      for (const auto& f : list) std::printf("    gelen: %s\n", f.c_str());
    }
    CHECK_THAT(same);
    CHECK_THAT(sanitize::fingerprint(str(c.find("type")), list) == str(c.find("fingerprint")));
  }
  // Unity ile aynı iv ve anahtarla aynı satır; ve çözme.
  const Value* aes = vectors.find("aes");
  for (std::size_t i = 0; aes != nullptr && i < aes->size(); ++i) {
    const Value& c = aes->at(i);
    const crypto::Bytes iv = hex(str(c.find("iv")));
    crypto::AesGcmPayloadCipher cipher(hex(str(c.find("key"))), [iv]() { return iv; });
    CHECK_THAT(cipher.encrypt(str(c.find("plain")), str(c.find("aad"))) == str(c.find("line")));
    std::string plain;
    // Boş gövde Unity'de de açılmaz (iv + etiket uzunluğundan büyük olmalı); olaylar zaten boş değildir.
    if (str(c.find("plain")).empty()) {
      CHECK_THAT(!cipher.decrypt(str(c.find("line")), str(c.find("aad")), plain));
    } else {
      CHECK_THAT(cipher.decrypt(str(c.find("line")), str(c.find("aad")), plain) && plain == str(c.find("plain")));
    }
    CHECK_THAT(!cipher.decrypt(str(c.find("line")), "BASKA", plain));
  }
  std::printf("crypto_test: %d denetim, %d kaldı\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
