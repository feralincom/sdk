// Gelir (feralin_purchase), profil (fr_group, fr_user_properties) ve hata (fr_error) sözleşmelerinin testleri.
// Temizleme vektörleri toplayıcının düzenli ifadeleriyle (services/collect/internal/httpapi/error_adrevenue_filter.go) Go'da üretildi.
#include <cmath>
#include <limits>
#include <memory>
#include <set>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

#include "test_support.hpp"

using feralin::Client;
using feralin::Consent;
using feralin::ErrorCode;
using feralin::ErrorReport;
using feralin::Options;
using feralin::Receipt;
using feralin::RevenueInput;
using feralin::TrackResult;
using feralin::Value;
using test::FakeTransport;
namespace signals = feralin::signals;

namespace {

Consent analytics() {
  Consent consent;
  consent.analytics = true;
  return consent;
}

std::unique_ptr<Client> make_client(const std::shared_ptr<FakeTransport>& transport, Options options = Options()) {
  options.project_key = test::kTestKey;
  options.collect_url = "https://collect.example.test";
  options.flush_interval_ms = 0;
  options.transport = transport;
  feralin::Error error;
  auto client = Client::create(std::move(options), &error);
  if (!client) throw std::runtime_error("istemci açılamadı: " + error.message);
  return client;
}

std::unique_ptr<Client> make_client(const std::shared_ptr<FakeTransport>& transport, Consent consent) {
  Options options;
  options.consent = consent;
  return make_client(transport, std::move(options));
}

Value properties_of(const TrackResult& result) {
  const Value event = test::parsed(result.event_json);
  const Value* props = event.find("properties");
  if (props == nullptr) throw std::runtime_error("properties yok");
  return *props;
}

RevenueInput valid_revenue() {
  RevenueInput input;
  input.transaction_id = "txn_1";
  input.amount_minor = 4999;
  input.currency = "TRY";
  return input;
}

}  // namespace

// ------------------------------------------------------------------ gelir

TEST_CASE(revenue_builds_contract_properties) {
  auto transport = std::make_shared<FakeTransport>();
  auto client = make_client(transport, analytics());
  RevenueInput input = valid_revenue();
  input.product_id = "pro_monthly";
  input.quantity = 2;
  input.purchase_type = "subscription_start";
  input.receipt = Receipt{"google", "purchase-token-1"};
  input.properties = Value::make_object();
  input.properties.set("plan", "pro");
  for (const char* reserved : {"verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"}) {
    input.properties.set(reserved, true);
  }
  const TrackResult result = client->track_revenue(input);
  ASSERT_TRUE(result.ok() && result.produced);
  const Value event = test::parsed(result.event_json);
  ASSERT_EQ(event.find("event_name")->as_string(), std::string("feralin_purchase"));
  const Value props = properties_of(result);
  ASSERT_EQ(props.find("transaction_id")->as_string(), std::string("txn_1"));
  ASSERT_TRUE(props.find("amount_minor")->is_integer());
  ASSERT_EQ(props.find("amount_minor")->as_int(), std::int64_t{4999});
  ASSERT_EQ(props.find("currency")->as_string(), std::string("TRY"));
  ASSERT_EQ(props.find("quantity")->as_int(), std::int64_t{2});
  ASSERT_EQ(props.find("purchase_type")->as_string(), std::string("subscription_start"));
  ASSERT_EQ(props.find("product_id")->as_string(), std::string("pro_monthly"));
  ASSERT_EQ(props.find("plan")->as_string(), std::string("pro"));
  ASSERT_EQ(props.find("receipt")->find("provider")->as_string(), std::string("google"));
  ASSERT_EQ(props.find("receipt")->find("token")->as_string(), std::string("purchase-token-1"));
  ASSERT_EQ(props.find("receipt")->size(), std::size_t{2});
  for (const char* reserved : {"verified", "verification", "verification_source", "receipt_provider", "receipt_digest"}) {
    ASSERT_TRUE(props.find(reserved) == nullptr);
  }
  ASSERT_TRUE(result.event_json.find("verified") == std::string::npos);
}

TEST_CASE(revenue_defaults_and_optional_fields) {
  auto transport = std::make_shared<FakeTransport>();
  auto client = make_client(transport, analytics());
  const TrackResult result = client->track_revenue(valid_revenue());
  ASSERT_TRUE(result.produced);
  const Value props = properties_of(result);
  ASSERT_EQ(props.find("quantity")->as_int(), std::int64_t{1});
  ASSERT_EQ(props.find("purchase_type")->as_string(), std::string("purchase"));
  ASSERT_TRUE(props.find("product_id") == nullptr);
  ASSERT_TRUE(props.find("receipt") == nullptr);

  RevenueInput zero = valid_revenue();
  zero.quantity = 0;
  zero.amount_minor = 0;
  ASSERT_TRUE(client->track_revenue(zero).produced);
  RevenueInput cancel = valid_revenue();
  cancel.amount_minor = 0;
  cancel.purchase_type = "subscription_cancel";
  ASSERT_TRUE(client->track_revenue(cancel).produced);
  RevenueInput top = valid_revenue();
  top.amount_minor = signals::kMaxAmountMinor;
  top.quantity = 100000;
  top.transaction_id = std::string(128, 'x');
  ASSERT_TRUE(client->track_revenue(top).produced);
}

TEST_CASE(revenue_rejects_invalid_input) {
  auto transport = std::make_shared<FakeTransport>();
  auto client = make_client(transport, analytics());
  std::vector<std::pair<const char*, RevenueInput>> cases;
  const auto add = [&cases](const char* name, RevenueInput input) { cases.emplace_back(name, std::move(input)); };
  RevenueInput input = valid_revenue();
  input.transaction_id.clear();
  add("boş transaction_id", input);
  input = valid_revenue();
  input.transaction_id = std::string(129, 'x');
  add("uzun transaction_id", input);
  input = valid_revenue();
  input.amount_minor = -1;
  add("negatif tutar", input);
  input = valid_revenue();
  input.amount_minor = signals::kMaxAmountMinor + 1;
  add("güvenli tam sayı üstü", input);
  for (const char* currency : {"try", "TR", "TRYY", "", "T1Y"}) {
    input = valid_revenue();
    input.currency = currency;
    add("para birimi", input);
  }
  input = valid_revenue();
  input.product_id = std::string(129, 'p');
  add("uzun product_id", input);
  input = valid_revenue();
  input.quantity = -1;
  add("negatif adet", input);
  input = valid_revenue();
  input.quantity = 100001;
  add("adet üstü", input);
  input = valid_revenue();
  input.purchase_type = "refund";
  add("bilinmeyen purchase_type", input);
  input = valid_revenue();
  input.purchase_type = "subscription_cancel";
  add("tutarlı iptal", input);
  input = valid_revenue();
  input.receipt = Receipt{"paypal", "t"};
  add("bilinmeyen makbuz sağlayıcısı", input);
  input = valid_revenue();
  input.receipt = Receipt{"apple", ""};
  add("boş makbuz belirteci", input);
  input = valid_revenue();
  input.receipt = Receipt{"apple", std::string(8193, 't')};
  add("uzun makbuz belirteci", input);
  input = valid_revenue();
  input.properties = Value("metin");
  add("nesne olmayan özellik", input);
  for (const auto& item : cases) {
    const TrackResult result = client->track_revenue(item.second);
    if (result.error.code != ErrorCode::invalid_event || result.produced) throw std::runtime_error(std::string("kabul edildi: ") + item.first);
  }
  ASSERT_EQ(client->queue_length(), std::size_t{0});
}

TEST_CASE(revenue_respects_consent) {
  auto transport = std::make_shared<FakeTransport>();
  auto client = make_client(transport, Consent());
  const TrackResult result = client->track_revenue(valid_revenue());
  ASSERT_TRUE(result.ok() && !result.produced);
}

// ------------------------------------------------------------------ profil

TEST_CASE(pii_like_keys_match_collector) {
  for (const char* key : {"email", "userEmail", "user_email", "phone_number", "phoneNumber", "firstName", "last_name", "name", "userName",
                          "displayName", "ip", "ipAddress", "home_address", "tckn", "birthDate", "dob", "isim", "ad", "Password1"}) {
    if (!signals::is_pii_like_key(key)) throw std::runtime_error(std::string("PII sayılmadı: ") + key);
  }
  for (const char* key : {"plan", "company_size", "tier", "addon", "admin", "industry", "seats", "nameless_count"}) {
    if (signals::is_pii_like_key(key)) throw std::runtime_error(std::string("yanlış PII: ") + key);
  }
}

TEST_CASE(email_like_values_match_go_regex) {
  const std::vector<std::pair<std::string, bool>> cases = {
      {"a@b.co", true},   {"a@b.c", true},   {"x @b.co", false}, {"a@ b.co", false}, {"a@b.", false},    {"a@.b", false},
      {"a@x.y z", true},  {"name", false},   {"@a.b", false},    {"a@b.c.d", true},  {"a@@b.co", false},
  };
  for (const auto& item : cases) {
    if (signals::looks_like_email(item.first) != item.second) throw std::runtime_error("e-posta sezgisi uyuşmadı: " + item.first);
  }
}

TEST_CASE(set_user_properties_sanitizes) {
  auto transport = std::make_shared<FakeTransport>();
  auto client = make_client(transport, analytics());
  Value props = Value::make_object();
  props.set("plan", "pro");
  props.set("seats", 12);
  props.set("ratio", 0.5);
  props.set("beta", true);
  props.set("email", "x@y.com");
  props.set("contact", "a@b.co");
  props.set("verified", true);
  props.set("nested", Value::make_object());
  props.set("list", Value::make_array());
  props.set("nothing", Value());
  props.set("bad key", "x");
  props.set("long", std::string(257, 'a'));
  props.set("ctrl", std::string("a\nb"));
  props.set("nan", std::numeric_limits<double>::quiet_NaN());
  const TrackResult result = client->set_user_properties_value(props);
  ASSERT_TRUE(result.ok() && result.produced);
  ASSERT_EQ(test::parsed(result.event_json).find("event_name")->as_string(), std::string("fr_user_properties"));
  const Value clean = properties_of(result);
  ASSERT_EQ(clean.size(), std::size_t{4});
  ASSERT_EQ(clean.find("plan")->as_string(), std::string("pro"));
  ASSERT_EQ(clean.find("seats")->as_int(), std::int64_t{12});
  ASSERT_TRUE(clean.find("ratio")->as_double() == 0.5);
  ASSERT_TRUE(clean.find("beta")->as_bool());

  const TrackResult empty = client->set_user_properties({{"email", "a@b.co"}, {"verified", true}});
  ASSERT_TRUE(empty.ok() && !empty.produced);
  ASSERT_EQ(client->queue_length(), std::size_t{1});
}

TEST_CASE(profile_limit_keeps_first_50_sorted_keys) {
  Value props = Value::make_object();
  for (int i = 59; i >= 0; --i) {
    std::string key = "k" + std::string(i < 10 ? "0" : "") + std::to_string(i);
    props.set(key, i);
  }
  const Value clean = signals::sanitize_profile_properties(props);
  ASSERT_EQ(clean.size(), std::size_t{50});
  ASSERT_EQ(clean.key_at(0), std::string("k00"));
  ASSERT_EQ(clean.key_at(49), std::string("k49"));
  ASSERT_TRUE(clean.find("k50") == nullptr);
}

TEST_CASE(group_event_and_invalid_ids) {
  auto transport = std::make_shared<FakeTransport>();
  auto client = make_client(transport, analytics());
  const TrackResult result = client->group("acme_corp", {{"plan", "enterprise"}, {"email", "a@b.co"}, {"group_id", "spoof"}});
  ASSERT_TRUE(result.ok() && result.produced);
  ASSERT_EQ(test::parsed(result.event_json).find("event_name")->as_string(), std::string("fr_group"));
  const Value props = properties_of(result);
  ASSERT_EQ(props.find("group_id")->as_string(), std::string("acme_corp"));
  ASSERT_EQ(props.find("plan")->as_string(), std::string("enterprise"));
  ASSERT_TRUE(props.find("email") == nullptr);

  ASSERT_TRUE(client->group("şirket").produced);
  ASSERT_TRUE(client->group(std::string(128, 'g')).produced);
  for (const std::string& id : {std::string(), std::string("   "), std::string("a@b"), std::string(129, 'g'), std::string("a\tb"), std::string("a\x7f")}) {
    const TrackResult rejected = client->group(id);
    ASSERT_TRUE(rejected.ok() && !rejected.produced);
  }
  ASSERT_EQ(client->queue_length(), std::size_t{3});
}

// ------------------------------------------------------------------ hata

TEST_CASE(scrub_matches_collector_vectors) {
  const std::vector<std::pair<std::string, std::string>> cases = {
      {"plain message", "plain message"},
      {"failed GET https://api.example.com/v1/users?id=5 now", "failed GET [url] now"},
      {"see HTTP://Example.COM/a and ftp://x.y", "see [url] and [url]"},
      {"1http://nope.example x", "1http://nope.example x"},
      {"a.b+c://host/path\"quoted\"", "[url]\"quoted\""},
      {"contact john.doe+tag@mail.example.co.uk please", "contact [email] please"},
      {"bad a@b.c x@y.com.z1 z@q", "bad a@b.c [email].z1 z@q"},
      {"user@@host.com and @x.com and a@b.c0m.de", "user@@host.com and @x.com and [email]"},
      {"id 123e4567-e89b-12d3-a456-426614174000 end", "id [id] end"},
      {"x123e4567-e89b-12d3-a456-426614174000", "[token]"},
      {"token abcdefghijklmnopqrstuvwx1234 and UnsupportedOperationExceptionX", "token [token] and UnsupportedOperationExceptionX"},
      {"Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0=", "Bearer eyJhbGciOiJIUzI1NiJ9.[token]="},
      {"key-ABCDEFGHIJKLMNOPQRSTUVW9 -ABCDEFGHIJKLMNOPQRSTUVWXYZ0-", "[token] -[token]-"},
      {"call +90 (532) 123-45-67 or 0212 555 1234", "call [num] or [num]"},
      {"version 1.4.2 build 2026.11.16 code 12345", "version 1.4.2 build [num] code 12345"},
      {"card 4111 1111 1111 1111 x", "card [num] x"},
      {"num 123456 and 1234567", "num 123456 and [num]"},
      {"tabs\tand\n\nnewlines   here  ", "tabs and newlines here"},
      {"ünicode ğüşiöç mesaj https://ö.example/ş 5551234567", "ünicode ğüşiöç mesaj [url] [num]"},
      {"mixed a1b2c3d4e5f6g7h8i9j0k1l2m3 tail", "mixed [token] tail"},
      {"path /home/user/file.txt:42", "path /home/user/file.txt:42"},
      {"+1234567", "[num]"},
      {"++12345678", "+[num]"},
      {"(555) 123-4567", "([num]"},
      {"12.34.56.78.90", "[num]"},
      {"====================aaaa1", "====================aaaa1"},
      {"aaaaaaaaaaaaaaaaaaaaaaaa1/", "[token]/"},
      {"x/aaaaaaaaaaaaaaaaaaaaaaaaa1", "[token]"},
  };
  for (const auto& item : cases) {
    const std::string actual = signals::scrub_error_message(item.first);
    if (actual != item.second) throw std::runtime_error("temizlik uyuşmadı: '" + item.first + "' → '" + actual + "', beklenen '" + item.second + "'");
  }
  std::string repeated;
  for (int i = 0; i < 30; ++i) repeated += "uzun mesaj ";
  const std::string truncated = signals::scrub_error_message(repeated);
  ASSERT_EQ(truncated.size(), std::size_t{200});
  ASSERT_EQ(truncated.substr(192), std::string("mesaj uz"));
  // Çok baytlı karakter ortadan kesilmez; NUL ve bozuk UTF-8 boşluğa döner.
  ASSERT_EQ(signals::code_points(signals::scrub_error_message(std::string(250, 'a') + "ş")), std::size_t{200});
  ASSERT_EQ(signals::scrub_error_message(std::string("a\0b\xff" "c", 5)), std::string("a b c"));
}

TEST_CASE(fingerprint_is_fnv1a64_hex) {
  ASSERT_EQ(signals::fnv1a64(""), std::string("cbf29ce484222325"));
  ASSERT_EQ(signals::fnv1a64("a"), std::string("af63dc4c8601ec8c"));
  ErrorReport report;
  report.error_type = "IOError";
  report.message = "disk 42 full";
  const Value props = signals::error_properties(report, "");
  ASSERT_EQ(props.find("fingerprint")->as_string(), signals::fnv1a64("IOError|disk # full"));
  ASSERT_EQ(props.find("frame_count")->as_int(), std::int64_t{0});
  ASSERT_TRUE(props.find("top_frame") == nullptr);
  // Rakam farkı parmak izini değiştirmez; çerçeve varsa mesaj parmak izine girmez.
  report.message = "disk 7 full";
  ASSERT_EQ(signals::error_properties(report, "").find("fingerprint")->as_string(), props.find("fingerprint")->as_string());
  report.frames = {"load@app", "main@app", "a@x", "b@x", "c@x", "d@x"};
  const Value framed = signals::error_properties(report, "");
  ASSERT_EQ(framed.find("fingerprint")->as_string(), signals::fnv1a64("IOError|load@app|main@app|a@x|b@x|c@x"));
  ASSERT_EQ(framed.find("top_frame")->as_string(), std::string("load@app"));
  ASSERT_EQ(framed.find("frame_count")->as_int(), std::int64_t{6});
}

TEST_CASE(error_properties_contract_fields) {
  ErrorReport report;
  report.error_type = "";
  report.message = "  mail me at a@b.co  ";
  report.frames = {std::string(300, 'f')};
  report.origin = "manual";
  report.fatal = true;
  const Value props = signals::error_properties(report, "1.2.3");
  ASSERT_EQ(props.find("error_type")->as_string(), std::string("Error"));
  ASSERT_EQ(props.find("message")->as_string(), std::string("mail me at [email]"));
  ASSERT_EQ(props.find("top_frame")->as_string().size(), std::size_t{160});
  ASSERT_EQ(props.find("app_version")->as_string(), std::string("1.2.3"));
  ASSERT_TRUE(props.find("handled")->as_bool());
  ASSERT_TRUE(props.find("fatal")->as_bool());
  ASSERT_EQ(props.find("origin")->as_string(), std::string("manual"));
  const std::string fingerprint = props.find("fingerprint")->as_string();
  ASSERT_EQ(fingerprint.size(), std::size_t{16});
  ASSERT_TRUE(fingerprint.find_first_not_of("0123456789abcdef") == std::string::npos);
  // Toplayıcının izin listesi dışında alan yok.
  const std::set<std::string> allowed = {"error_type", "message", "fingerprint", "top_frame", "frame_count", "app_version", "handled", "fatal", "origin", "frames"};
  for (std::size_t i = 0; i < props.size(); ++i) ASSERT_TRUE(allowed.count(props.key_at(i)) == 1);

  report.origin = "uncaught_exception";
  report.message.clear();
  const Value uncaught = signals::error_properties(report, std::string(33, 'v'));
  ASSERT_TRUE(!uncaught.find("handled")->as_bool());
  ASSERT_TRUE(uncaught.find("message") == nullptr);
  ASSERT_TRUE(uncaught.find("app_version") == nullptr);
  ASSERT_EQ(signals::error_properties(ErrorReport{std::string(70, 'T'), "", {}, "handled", false}, "").find("error_type")->as_string().size(), std::size_t{64});
}

TEST_CASE(capture_error_from_std_exception) {
  auto transport = std::make_shared<FakeTransport>();
  Options options;
  options.consent = analytics();
  options.app_version = "3.1.0";
  auto client = make_client(transport, std::move(options));
  TrackResult result;
  try {
    throw std::out_of_range("index 1234567 out of range for user a@b.co");
  } catch (const std::exception& error) {
    result = client->capture_error(error);
  }
  ASSERT_TRUE(result.ok() && result.produced);
  const Value event = test::parsed(result.event_json);
  ASSERT_EQ(event.find("event_name")->as_string(), std::string("fr_error"));
  const Value props = *event.find("properties");
#if defined(__cpp_rtti) || defined(__GXX_RTTI) || defined(_CPPRTTI)
  ASSERT_EQ(props.find("error_type")->as_string(), std::string("out_of_range"));
#endif
  ASSERT_EQ(props.find("message")->as_string(), std::string("index [num] out of range for user [email]"));
  ASSERT_EQ(props.find("origin")->as_string(), std::string("handled"));
  ASSERT_TRUE(props.find("handled")->as_bool());
  ASSERT_TRUE(!props.find("fatal")->as_bool());
  ASSERT_EQ(props.find("app_version")->as_string(), std::string("3.1.0"));
  ASSERT_TRUE(props.find("stack") == nullptr);
  ASSERT_TRUE(client->flush().ok());
  ASSERT_EQ(transport->count(), std::size_t{1});

  ErrorReport bad;
  bad.origin = "window_onerror";
  ASSERT_TRUE(client->capture_error(bad).error.code == ErrorCode::invalid_event);
}

TEST_CASE(capture_error_limits_and_consent) {
  auto transport = std::make_shared<FakeTransport>();
  auto client = make_client(transport, Consent());
  const std::runtime_error same("boom");
  // İzin yokken sınır sayacı harcanmaz.
  for (int i = 0; i < 30; ++i) ASSERT_TRUE(!client->capture_error(same).produced);
  client->set_consent(analytics());
  int produced = 0;
  for (int i = 0; i < 5; ++i) produced += client->capture_error(same).produced ? 1 : 0;
  ASSERT_EQ(produced, 3);
  for (int i = 0; i < 40; ++i) {
    ErrorReport report;
    report.error_type = "E" + std::string(1, static_cast<char>('a' + (i % 26))) + std::string(1, static_cast<char>('a' + (i / 26)));
    produced += client->capture_error(report).produced ? 1 : 0;
  }
  ASSERT_EQ(produced, 20);

  Options sampled;
  sampled.consent = analytics();
  sampled.error_sample_rate = 0.0;
  auto never = make_client(transport, std::move(sampled));
  ASSERT_TRUE(!never->capture_error(same).produced);
  ASSERT_EQ(never->queue_length(), std::size_t{0});
}

TEST_CASE(error_type_name_strips_namespaces) {
#if defined(__cpp_rtti) || defined(__GXX_RTTI) || defined(_CPPRTTI)
  ASSERT_EQ(feralin::error_type_name(std::runtime_error("x")), std::string("runtime_error"));
  ASSERT_EQ(feralin::error_type_name(std::invalid_argument("x")), std::string("invalid_argument"));
#else
  ASSERT_EQ(feralin::error_type_name(std::runtime_error("x")), std::string("Error"));
#endif
}

int main() { return test::run_all(); }
