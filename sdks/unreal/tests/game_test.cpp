// Oyun sözleşmeleri ve Client mantığı (FeralinGame.hpp): Unity çıktılarıyla vektör karşılaştırması, kalıcı şifreli kuyruk, hata, oturum, atıf.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "FeralinGame.hpp"

namespace g = feralin::game;
namespace w = feralin::wire;
namespace crypto = feralin::crypto;
using w::Value;

static int g_checks = 0, g_failures = 0;
#define CHECK_THAT(c) do { ++g_checks; if (!(c)) { ++g_failures; std::printf("KALDI %s:%d: %s\n", __FILE__, __LINE__, #c); } } while (0)

static std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

static std::string str(const Value* v) { return v != nullptr && v->is_string() ? v->as_string() : std::string(); }

static bool same(const Value& a, const Value& b) {
  if (a.is_object() != b.is_object() || a.is_string() != b.is_string()) return false;
  if (a.is_string()) return a.as_string() == b.as_string();
  if (a.is_object()) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i) {
      const Value* other = b.find(a.key_at(i));
      if (other == nullptr || !same(a.at(i), *other)) return false;
    }
    return true;
  }
  if (a.type() != b.type()) return false;
  if (a.type() == Value::Type::boolean) return a.as_bool() == b.as_bool();
  if (a.type() == Value::Type::integer) return a.as_int() == b.as_int();
  return a.type() == Value::Type::null;
}

static std::optional<std::string> opt(const Value& v, const char* key) {
  const Value* f = v.find(key);
  if (f == nullptr || !f->is_string()) return std::nullopt;
  return f->as_string();
}

static void vector_tests(const std::string& dir) {
  Value vectors;
  CHECK_THAT(w::parse_json(read_file(dir + "/vectors/sdk_vectors.json"), vectors));
  const Value* revenue = vectors.find("revenue");
  for (std::size_t i = 0; revenue != nullptr && i < revenue->size(); ++i) {
    const Value& c = revenue->at(i);
    const Value& in = *c.find("input");
    g::RevenueInput input;
    input.transaction_id = str(in.find("transaction_id"));
    input.amount_minor = in.find("amount_minor")->as_int();
    input.currency = str(in.find("currency"));
    input.product_id = opt(in, "product_id");
    input.quantity = static_cast<int>(in.find("quantity")->as_int());
    const std::string type = str(in.find("purchase_type"));
    input.purchase_type = type == "subscription_start" ? g::PurchaseType::subscription_start : type == "subscription_renew" ? g::PurchaseType::subscription_renew
                          : type == "subscription_cancel" ? g::PurchaseType::subscription_cancel : g::PurchaseType::purchase;
    if (const auto provider = opt(in, "receipt_provider")) {
      g::Receipt receipt;
      receipt.provider = *provider == "apple" ? g::ReceiptProvider::apple : *provider == "google" ? g::ReceiptProvider::google : g::ReceiptProvider::stripe;
      receipt.token = str(in.find("receipt_token"));
      input.receipt = receipt;
    }
    if (const Value* p = in.find("properties")) input.properties = *p;
    const auto actual = g::revenue_properties(input);
    const Value* expected = c.find("props");
    const bool both_null = !actual && (expected == nullptr || expected->is_null());
    const bool equal = actual && expected != nullptr && same(*actual, *expected);
    if (!(both_null || equal)) std::printf("  revenue[%zu] uyuşmadı (islem %s)\n", i, input.transaction_id.c_str());
    CHECK_THAT(both_null || equal);
  }
  const Value* ads = vectors.find("adrevenue");
  for (std::size_t i = 0; ads != nullptr && i < ads->size(); ++i) {
    const Value& c = ads->at(i);
    const Value& in = *c.find("input");
    g::AdRevenueInput input;
    input.network = str(in.find("network"));
    const std::string format = str(in.find("ad_format"));
    input.ad_format = format == "banner" ? g::AdFormat::banner : format == "interstitial" ? g::AdFormat::interstitial : format == "rewarded" ? g::AdFormat::rewarded
                      : format == "rewarded_interstitial" ? g::AdFormat::rewarded_interstitial : format == "native" ? g::AdFormat::native : format == "app_open" ? g::AdFormat::app_open : g::AdFormat::other;
    input.revenue_micros = in.find("revenue_micros")->as_int();
    input.currency = str(in.find("currency"));
    input.ad_unit = opt(in, "ad_unit");
    const std::string precision = str(in.find("precision"));
    input.precision = precision == "estimated" ? g::AdPrecision::estimated : precision == "publisher_provided" ? g::AdPrecision::publisher_provided : precision == "precise" ? g::AdPrecision::precise : g::AdPrecision::unknown;
    input.placement = opt(in, "placement");
    input.impression_id = opt(in, "impression_id");
    if (const Value* p = in.find("properties")) input.properties = *p;
    const auto actual = g::ad_revenue_properties(input);
    const Value* expected = c.find("props");
    const bool both_null = !actual && (expected == nullptr || expected->is_null());
    const bool equal = actual && expected != nullptr && same(*actual, *expected);
    if (!(both_null || equal)) std::printf("  adrevenue[%zu] uyuşmadı (ağ %s)\n", i, input.network.c_str());
    CHECK_THAT(both_null || equal);
  }
}

// ---------------------------------------------------------------- Client

struct Fixture {
  std::int64_t now = 1793700000000;
  std::int64_t mono = 1000;
  unsigned counter = 1;
  std::vector<std::string> logs;
  crypto::Bytes key = crypto::Bytes(32, 7);
  std::string dir;

  g::Environment env() {
    g::Environment e;
    e.now_ms = [this]() { return now; };
    e.mono_ms = [this]() { return mono; };
    e.fill = [this](unsigned char* buffer, std::size_t length) {
      for (std::size_t i = 0; i < length; ++i) buffer[i] = static_cast<unsigned char>((counter++ * 37u) & 0xFFu);
    };
    e.unit_random = []() { return 0.0; };
    e.log = [this](const std::string& m) { logs.push_back(m); };
    return e;
  }

  std::unique_ptr<crypto::EventStore> store(const crypto::Bytes& use_key) {
    auto inner = std::make_unique<crypto::FileEventStore>(dir);
    unsigned* c = &counter;
    crypto::AesGcmPayloadCipher cipher(use_key, [c]() {
      crypto::Bytes iv(12);
      for (auto& b : iv) b = static_cast<std::uint8_t>((*c)++ * 91u);
      return iv;
    });
    return std::make_unique<crypto::EncryptedEventStore>(std::move(inner), std::move(cipher));
  }

  std::unique_ptr<g::Client> client(bool persistent = true, g::Options base = g::Options()) {
    base.sdk = w::SdkIdentity{"feralin-unreal", "0.2.0", "unreal"};
    base.project_key = "pk_test_unreal_game_01";
    return std::make_unique<g::Client>(base, env(), persistent ? store(key) : nullptr);
  }
};

static w::Consent consent(bool analytics, bool advertising = false) {
  w::Consent c;
  c.analytics = analytics;
  c.advertising = advertising;
  return c;
}

static Value parse(const std::string& json) {
  Value v;
  w::parse_json(json, v);
  return v;
}

static std::vector<Value> queued_events(g::Client& client) {
  std::vector<Value> out;
  for (const auto& item : client.core().peek()) out.push_back(parse(item.json));
  return out;
}

static Value obj(std::initializer_list<std::pair<const char*, Value>> items) {
  Value v = Value::make_object();
  for (const auto& i : items) v.set(i.first, i.second);
  return v;
}

static std::string fresh_dir(const std::string& base, const char* name) {
  const std::string dir = base + "/tmp_" + name;
  std::error_code ec;
  std::filesystem::remove_all(dir, ec);
  std::filesystem::create_directories(dir, ec);
  return dir;
}

static void test_persistence(const std::string& base) {
  Fixture f;
  f.dir = fresh_dir(base, "persist");
  std::vector<std::string> ids;
  {
    auto a = f.client();
    a->set_consent(consent(true));
    for (int i = 0; i < 3; ++i) {
      const auto r = a->track("level_started", obj({{"n", i}}));
      CHECK_THAT(r.produced);
      ids.push_back(r.event_id);
    }
  }
  const std::string disk = read_file(f.dir + "/events.log");
  CHECK_THAT(disk.find("enc1:") != std::string::npos);
  CHECK_THAT(disk.find("level_started") == std::string::npos);
  CHECK_THAT(disk.find(ids[0]) == 0);
  // Yeniden başlatma: aynı event_id'ler aynı sırayla, izin verilince geri yüklenir.
  auto b = f.client();
  CHECK_THAT(b->core().queued() == 0);
  b->set_consent(consent(true));
  CHECK_THAT(b->core().queued() == 3);
  const auto batch = b->core().peek();
  CHECK_THAT(batch.size() == 3 && batch[0].id == ids[0] && batch[1].id == ids[1] && batch[2].id == ids[2]);
  // Aynı idempotency anahtarı: tekrar gönderim ikinci outbox satırı yazdırmaz.
  const std::string key_first = w::EventCore::batch_key(batch);
  auto c = f.client();
  c->set_consent(consent(true));
  CHECK_THAT(w::EventCore::batch_key(c->core().peek()) == key_first);
  // Kabul edilince diskten silinir.
  const w::DeliveryResult ok = b->deliver_response(batch, 202, "{\"accepted\":3,\"rejected\":0}", "");
  CHECK_THAT(ok.accepted == 3);
  CHECK_THAT(read_file(f.dir + "/events.log").empty());
  // Geçici hatada kalır.
  auto d = f.client();
  d->set_consent(consent(true));
  d->track("a", Value());
  const auto pending = d->core().peek();
  d->deliver_response(pending, 503, "", "");
  CHECK_THAT(!read_file(f.dir + "/events.log").empty() && d->core().queued() == 1);
  // 401: bütün kuyruk ve depo temizlenir.
  d->deliver_response(d->core().peek(), 401, "", "");
  CHECK_THAT(read_file(f.dir + "/events.log").empty() && d->core().queued() == 0);
}

static void test_store_edge_cases(const std::string& base) {
  Fixture f;
  f.dir = fresh_dir(base, "edge");
  {
    auto a = f.client();
    a->set_consent(consent(true));
    a->track("x", Value());
  }
  // Yanlış anahtar: satırlar açılmaz ve atılır; düz metne düşülmez.
  Fixture other = f;
  other.key = crypto::Bytes(32, 9);
  auto wrong = other.client();
  wrong->set_consent(consent(true));
  CHECK_THAT(wrong->core().queued() == 0);
  CHECK_THAT(read_file(f.dir + "/events.log").empty());
  // İzin reddi diskteki olayı siler.
  {
    auto a = f.client();
    a->set_consent(consent(true));
    a->track("y", Value());
  }
  auto denied = f.client();
  denied->set_consent(consent(false));
  CHECK_THAT(read_file(f.dir + "/events.log").empty());
  // Yarım kalmış satır ve bozuk satır yok sayılır, sonraki olay bozuk satıra yapışmaz.
  {
    std::ofstream out(f.dir + "/events.log", std::ios::binary | std::ios::app);
    out << "01ARZ3NDEKTSV4RRFFQ69G5FAV\tenc1:abcd";
  }
  auto after = f.client();
  after->set_consent(consent(true));
  const auto t = after->track("z", Value());
  CHECK_THAT(t.produced);
  auto reload = f.client();
  reload->set_consent(consent(true));
  CHECK_THAT(reload->core().queued() == 1);
  // Kuyruk sınırı diske de uygulanır.
  Fixture lim;
  lim.dir = fresh_dir(base, "limit");
  g::Options opt;
  opt.queue_limit = 3;
  auto limited = lim.client(true, opt);
  limited->set_consent(consent(true));
  std::vector<std::string> ids;
  for (int i = 0; i < 5; ++i) ids.push_back(limited->track("e", obj({{"i", i}})).event_id);
  CHECK_THAT(limited->core().queued() == 3);
  auto restarted = lim.client(true, opt);
  restarted->set_consent(consent(true));
  const auto batch = restarted->core().peek();
  CHECK_THAT(batch.size() == 3 && batch[0].id == ids[2] && batch[2].id == ids[4]);
  // Kalıcı depo yoksa bellekte çalışır.
  auto memory = lim.client(false);
  memory->set_consent(consent(true));
  CHECK_THAT(memory->track("m", Value()).produced && !memory->persistent());
}

static void test_contracts(const std::string& base) {
  Fixture f;
  f.dir = fresh_dir(base, "contracts");
  auto c = f.client();
  CHECK_THAT(!c->track("a", Value()).produced);  // izin kararı yok
  c->set_consent(consent(true, true));
  g::RevenueInput r;
  r.transaction_id = "tx1";
  r.amount_minor = 4999;
  r.currency = "TRY";
  r.product_id = std::string("gold");
  r.properties = obj({{"verified", true}, {"note", "x"}});
  CHECK_THAT(c->track_revenue(r).produced);
  r.amount_minor = -1;
  CHECK_THAT(!c->track_revenue(r).produced);
  CHECK_THAT(c->track_iap_purchase("p", 4.99, "USD", "tx2", Value()).produced);
  CHECK_THAT(!c->track_iap_purchase("p", 4.99, "USD", "", Value()).produced);
  CHECK_THAT(c->track_iap_purchase("p", 500, "JPY", "tx3", Value()).produced);
  g::AdRevenueInput ad;
  ad.network = "admob";
  ad.revenue_micros = 12500;
  ad.currency = "USD";
  CHECK_THAT(c->track_ad_revenue(ad).produced);
  ad.network = "AdMob";
  CHECK_THAT(!c->track_ad_revenue(ad).produced);
  CHECK_THAT(c->group("clan_1", obj({{"size", 5}})).produced && !c->group("", Value()).produced);
  CHECK_THAT(c->set_user_properties(obj({{"tier", "gold"}})).produced && !c->set_user_properties(obj({{"bad key", 1}})).produced);
  const auto events = queued_events(*c);
  CHECK_THAT(events.size() == 6);
  const Value& purchase = *events[0].find("properties");
  CHECK_THAT(purchase.find("verified") == nullptr && purchase.find("amount_minor")->as_int() == 4999 && str(purchase.find("purchase_type")) == "purchase");
  CHECK_THAT(events[1].find("properties")->find("amount_minor")->as_int() == 499);
  CHECK_THAT(events[2].find("properties")->find("amount_minor")->as_int() == 500);
  CHECK_THAT(str(events[0].find("event_name")) == "feralin_purchase" && str(events[3].find("event_name")) == "fr_ad_revenue");
  CHECK_THAT(events[3].find("properties")->find("revenue_micros")->as_int() == 12500);
  CHECK_THAT(str(events[4].find("event_name")) == "fr_group" && str(events[5].find("event_name")) == "fr_user_properties");
  // Oyun olayları game-events.md ile aynı.
  CHECK_THAT(g::level_properties("l1", 2, std::nullopt, std::nullopt, std::nullopt, Value()).has_value());
  CHECK_THAT(!g::level_properties("", std::nullopt, std::nullopt, std::nullopt, std::nullopt, Value()));
  CHECK_THAT(!g::level_properties(std::string(65, 'a'), std::nullopt, std::nullopt, std::nullopt, std::nullopt, Value()));
  CHECK_THAT(!g::level_properties("l", 0, std::nullopt, std::nullopt, std::nullopt, Value()));
  CHECK_THAT(!g::level_properties("l", std::nullopt, -1, std::nullopt, std::nullopt, Value()));
  CHECK_THAT(g::level_properties("l", std::nullopt, 0, 86400000, std::string("boss"), Value()).has_value());
  CHECK_THAT(!g::level_properties("l", std::nullopt, std::nullopt, 86400001, std::nullopt, Value()));
  CHECK_THAT(!g::level_properties("l", std::nullopt, std::nullopt, std::nullopt, std::string(65, 'r'), Value()));
  CHECK_THAT(g::economy_properties("gem", 1, std::nullopt, std::nullopt, Value()).has_value() && g::economy_properties("gem", 1000000000000, std::nullopt, std::nullopt, Value()).has_value());
  CHECK_THAT(!g::economy_properties("gem", 0, std::nullopt, std::nullopt, Value()) && !g::economy_properties("gem", 1000000000001, std::nullopt, std::nullopt, Value()));
  CHECK_THAT(!g::economy_properties("", 5, std::nullopt, std::nullopt, Value()));
  CHECK_THAT(g::rewarded_shown_properties("p", std::string("admob"), Value()).has_value() && !g::rewarded_shown_properties("", std::nullopt, Value()));
  CHECK_THAT(g::rewarded_complete_properties("p", std::nullopt, 0, std::string("gem"), Value()).has_value() && !g::rewarded_complete_properties("p", std::nullopt, -1, std::nullopt, Value()));
  CHECK_THAT(g::iap_offer_properties("sku", std::nullopt, Value()).has_value() && !g::iap_offer_properties(std::string(129, 's'), std::nullopt, Value()));
  CHECK_THAT(g::iap_initiated_properties("sku", std::nullopt, std::string("tx"), Value()).has_value() && !g::iap_initiated_properties("sku", std::nullopt, std::string(129, 't'), Value()));
  CHECK_THAT(c->track_game("level_start", g::level_properties("l1", 1, std::nullopt, std::nullopt, std::nullopt, Value())).produced);
  CHECK_THAT(!c->track_game("level_start", g::level_properties("", 1, std::nullopt, std::nullopt, std::nullopt, Value())).produced);
}

static void test_errors_and_session(const std::string& base) {
  Fixture f;
  f.dir = fresh_dir(base, "errors");
  g::Options opt;
  opt.errors.max_per_minute = 3;
  opt.errors.max_per_fingerprint_per_minute = 2;
  auto c = f.client(true, opt);
  c->set_app_version("1.2.3");
  CHECK_THAT(!c->capture_error("Boom", "x", "", true, "manual").produced);  // izin yok
  c->set_consent(consent(true));
  const auto first = c->capture_error("NullReference ali@example.com", "kullanıcı ali@example.com token=abc /Users/ali/x", "A.B (at /Users/ali/a.cs:10)\nC.D () (at b.cs:2)", false, g::error_source::unhandled_exception);
  CHECK_THAT(first.produced);
  const Value event = queued_events(*c)[0];
  const Value& p = *event.find("properties");
  CHECK_THAT(str(event.find("event_name")) == "fr_error");
  CHECK_THAT(str(p.find("fingerprint")).size() == 16 && p.find("frame_count")->as_int() == 2 && p.find("fatal")->as_bool() && !p.find("handled")->as_bool());
  CHECK_THAT(str(p.find("origin")) == "uncaught_exception" && str(p.find("app_version")) == "1.2.3");
  const std::string flat = str(p.find("message")) + str(p.find("error_type")) + str(p.find("top_frame"));
  CHECK_THAT(flat.find("ali") == std::string::npos && flat.find("example.com") == std::string::npos && flat.find("abc") == std::string::npos);
  // Alan kümesi şemayla aynı: başka alan yok.
  for (std::size_t i = 0; i < p.size(); ++i) {
    const std::string k = p.key_at(i);
    CHECK_THAT(k == "error_type" || k == "message" || k == "fingerprint" || k == "top_frame" || k == "frame_count" || k == "app_version" || k == "handled" || k == "fatal" || k == "origin");
  }
  // Parmak izi başına dakikada 2; sonra bastırılır, pencere geçince tekrar alınır.
  CHECK_THAT(c->capture_error("Same", "m", "S.T ()", true, "manual").produced);
  CHECK_THAT(c->capture_error("Same", "m", "S.T ()", true, "manual").produced);
  CHECK_THAT(!c->capture_error("Same", "m", "S.T ()", true, "manual").produced);
  CHECK_THAT(c->errors_suppressed() == 1);
  f.now += 61000;
  CHECK_THAT(c->capture_error("Same", "m", "S.T ()", true, "manual").produced);
  // Genel sınır dakikada 3.
  CHECK_THAT(c->capture_error("Other1", "m", "", true, "manual").produced);
  CHECK_THAT(c->capture_error("Other2", "m", "", true, "manual").produced);
  CHECK_THAT(!c->capture_error("Other3", "m", "", true, "manual").produced);
  // Örnekleme: sample_rate 0 hiç göndermez.
  g::Options none;
  none.errors.sample_rate = 0;
  Fixture f2;
  f2.dir = fresh_dir(base, "errors2");
  auto s = f2.client(true, none);
  s->set_consent(consent(true));
  CHECK_THAT(!s->capture_error("Boom", "m", "", true, "manual").produced);

  // Oturum: 30 dakikadan kısa ayrılıkta aynı, uzunda yeni.
  Fixture f3;
  f3.dir = fresh_dir(base, "session");
  auto t = f3.client();
  t->set_consent(consent(true));
  const std::string session = t->session_id();
  CHECK_THAT(session.size() == 26);
  t->notify_background();
  f3.now += 29 * 60 * 1000;
  t->notify_foreground();
  CHECK_THAT(t->session_id() == session);
  t->notify_background();
  f3.now += 30 * 60 * 1000;
  t->notify_foreground();
  CHECK_THAT(t->session_id() != session);
  t->track("a", Value());
  CHECK_THAT(str(queued_events(*t)[0].find("session_id")) == t->session_id());
}

static void test_attribution(const std::string& base) {
  Fixture f;
  f.dir = fresh_dir(base, "attr");
  auto c = f.client();
  int reads = 0;
  c->start_attribution([&reads](std::function<void(bool, const std::string&)> done) {
    ++reads;
    done(true, "utm_source=google&utm_medium=cpc&fr_click=clk_abc&fr_dl=%2Fpromo%2F1&evil=1");
  });
  CHECK_THAT(reads == 0);  // izin kararı yok
  c->set_consent(consent(true, true));
  CHECK_THAT(reads == 1);
  auto events = queued_events(*c);
  CHECK_THAT(events.size() == 1 && str(events[0].find("event_name")) == "app_first_open");
  const Value& props = *events[0].find("properties");
  CHECK_THAT(str(props.find("attribution_source")) == "play_install_referrer" && str(props.find("fr_click")) == "clk_abc" && str(props.find("utm_source")) == "google");
  CHECK_THAT(props.find("evil") == nullptr && props.find("fr_dl") == nullptr);
  CHECK_THAT(c->consume_deferred_deep_link() == "/promo/1" && c->consume_deferred_deep_link().empty());
  // İkinci açılışta referrer yeniden okunmaz, ilk açılış tekrarlanmaz.
  auto again = f.client();
  int rereads = 0;
  again->start_attribution([&rereads](std::function<void(bool, const std::string&)> done) { ++rereads; done(false, ""); });
  again->set_consent(consent(true, true));
  CHECK_THAT(rereads == 0);
  // Reklam izni yoksa referrer okunmaz ve olay kanıtsızdır.
  Fixture f2;
  f2.dir = fresh_dir(base, "attr2");
  auto d = f2.client();
  int reads2 = 0;
  d->start_attribution([&reads2](std::function<void(bool, const std::string&)> done) { ++reads2; done(true, "fr_click=zzz"); });
  d->set_consent(consent(true, false));
  CHECK_THAT(reads2 == 0);
  CHECK_THAT(str(queued_events(*d)[0].find("properties")->find("attribution_source")) == "none");
  CHECK_THAT(d->consume_deferred_deep_link().empty());
  // Sonradan verilen reklam izni referrer'ı bir kez okur ve işaretli deep_link_opened taşır.
  d->set_consent(consent(true, true));
  CHECK_THAT(reads2 == 1);
  bool followup = false;
  for (const Value& e : queued_events(*d)) {
    if (str(e.find("event_name")) == "deep_link_opened") followup = e.find("properties")->find("consent_followup") != nullptr && str(e.find("properties")->find("fr_click")) == "zzz";
  }
  CHECK_THAT(followup);
  // Organik varsayılan kanıt sayılmaz.
  Fixture f3;
  f3.dir = fresh_dir(base, "attr3");
  auto e = f3.client();
  e->start_attribution([](std::function<void(bool, const std::string&)> done) { done(true, "utm_source=google-play&utm_medium=organic"); });
  e->set_consent(consent(true, true));
  CHECK_THAT(str(queued_events(*e)[0].find("properties")->find("attribution_source")) == "none");
  // Derin bağlantı: yalnız http(s); sorgudan yalnız fr_click, utm_*; ham URL saklanmaz; karardan önce gelen bekletilir.
  Fixture f4;
  f4.dir = fresh_dir(base, "attr4");
  auto l = f4.client();
  l->handle_deep_link("myapp://open?fr_click=x");
  l->handle_deep_link("https://Shop.Example.com:443/p/1?fr_click=clk9&utm_campaign=c&email=a@b.com&token=1#frag");
  l->set_consent(consent(true, true));
  const auto links = queued_events(*l);
  CHECK_THAT(links.size() == 1 && str(links[0].find("event_name")) == "deep_link_opened");
  const Value& lp = *links[0].find("properties");
  CHECK_THAT(str(lp.find("attribution_source")) == "app_link" && str(lp.find("fr_click")) == "clk9" && str(lp.find("utm_campaign")) == "c");
  CHECK_THAT(lp.find("email") == nullptr && lp.find("token") == nullptr);
  CHECK_THAT(str(links[0].find("context")->find("page_url")) == "https://shop.example.com/p/1");
  CHECK_THAT(!g::parse_deep_link("ftp://x/y") && !g::parse_deep_link("not a url") && g::parse_deep_link("http://a.b").has_value());
  CHECK_THAT(g::valid_deep_link_path("/a/b?x=1") && !g::valid_deep_link_path("//evil") && !g::valid_deep_link_path("/%2e%2e/x") && !g::valid_deep_link_path("/../x") && !g::valid_deep_link_path("x") && !g::valid_deep_link_path("/a%"));
  // İzin yoksa kanıt yok.
  l->handle_deep_link("https://a.b/c?fr_click=zz");
  CHECK_THAT(queued_events(*l).size() == 2);
  auto none = f4.client(false);
  none->set_consent(consent(true, false));
  none->handle_deep_link("https://a.b/c?fr_click=zz&utm_source=q");
  CHECK_THAT(str(queued_events(*none)[0].find("properties")->find("attribution_source")) == "none" && queued_events(*none)[0].find("properties")->find("fr_click") == nullptr);
}

static void test_bind_install(const std::string& base) {
  Fixture f;
  f.dir = fresh_dir(base, "bind");
  g::Options opt;
  opt.attribution_api_url = "https://api.feralin.test/";
  opt.project_id = "proj_1";
  auto c = f.client(true, opt);
  std::string status;
  std::string install;
  const auto done = [&](const g::InstallBinding& b) { status = b.status; install = b.install_id; };
  const g::TokenReader token = [](std::function<void(const g::TokenResult&)> cb) { cb(g::TokenResult{"token", "TOKEN123"}); };
  std::string url, body, auth;
  int respond = 202;
  const g::HttpPost post = [&](const std::string& u, const w::Headers& h, const std::string& b, std::function<void(int)> cb) {
    url = u;
    body = b;
    for (const auto& p : h) if (p.first == "Authorization") auth = p.second;
    cb(respond);
  };
  c->set_consent(consent(true, false));
  c->bind_install(token, post, done);
  CHECK_THAT(status == "skipped_no_consent" && install.empty() && url.empty());
  c->set_consent(consent(true, true));
  c->bind_install(token, post, done);
  CHECK_THAT(status == "received" && install.size() == 26);
  CHECK_THAT(url == "https://api.feralin.test/v1/projects/proj_1/attribution/apple-adservices/tokens");
  CHECK_THAT(body.find("TOKEN123") != std::string::npos && body.find(install) != std::string::npos && auth == "Bearer pk_test_unreal_game_01");
  const std::string first_install = install;
  respond = 503;
  c->bind_install(token, post, done);
  CHECK_THAT(status == "temporary_failure" && install == first_install);  // kimlik kalıcı
  respond = 400;
  c->bind_install(token, post, done);
  CHECK_THAT(status == "rejected");
  c->bind_install([](std::function<void(const g::TokenResult&)> cb) { cb(g::TokenResult{"unsupported", ""}); }, post, done);
  CHECK_THAT(status == "unsupported");
  c->bind_install([](std::function<void(const g::TokenResult&)> cb) { cb(g::TokenResult{"failed", ""}); }, post, done);
  CHECK_THAT(status == "token_unavailable");
  // Yapılandırma yoksa.
  auto plain = f.client(false);
  plain->set_consent(consent(true, true));
  plain->bind_install(token, post, done);
  CHECK_THAT(status == "not_configured");
  // ATT reddi reklam kanıtını kapatır.
  g::Options denied = opt;
  denied.tracking_status = []() { return g::TrackingStatus::denied; };
  auto att = f.client(true, denied);
  att->set_consent(consent(true, true));
  att->bind_install(token, post, done);
  CHECK_THAT(status == "skipped_no_consent");
  // Anahtar sızıntısı: günlüklerde proje anahtarı ve token yok.
  for (const std::string& line : f.logs) CHECK_THAT(line.find("TOKEN123") == std::string::npos);
}

// Kurulum eşleştirme kodu: biçim Web/Android SDK ve toplayıcıyla aynı; yalnız ilk üretilen olaya eklenir.
static void test_install_code(const std::string& base) {
  CHECK_THAT(g::normalize_install_code(" 7KQ2-M9XA4P\t") == "7KQ2-M9XA4P");
  CHECK_THAT(g::normalize_install_code("abcdefghjk") == "abcdefghjk");
  CHECK_THAT(g::normalize_install_code("7KQ2 M9XA_4P") == "7KQ2 M9XA_4P");
  CHECK_THAT(g::normalize_install_code("0123456789ABCDEF") == "0123456789ABCDEF");
  for (const char* bad : {"", "123456789", "0123456789ABCDEFG", "ABCDEFGHI0", "ABCDEFGHL0", "ABCDEFGHO0", "ABCDEFGHU0", "abcdefghi0", "12345678.0", "1234567890\xc5\x9f"}) {
    CHECK_THAT(g::normalize_install_code(bad).empty());
  }

  Fixture f;
  f.dir = fresh_dir(base, "install");
  g::Options options;
  options.install_code = " 7KQ2-M9XA4P ";
  auto c = f.client(false, options);
  CHECK_THAT(c->pending_install_code() == "7KQ2-M9XA4P");
  // İzin yokken olay üretilmez; kod beklemede kalır.
  CHECK_THAT(!c->track("app_open", Value()).produced && c->pending_install_code() == "7KQ2-M9XA4P");
  c->set_consent(consent(true));
  // Özellik sınırı doluysa kod bu olaya sığmaz, sonraki olayı bekler.
  Value full = Value::make_object();
  for (int i = 0; i < 100; ++i) full.set("k" + std::to_string(i), i);
  CHECK_THAT(c->track("big", full).produced && c->pending_install_code() == "7KQ2-M9XA4P");
  CHECK_THAT(c->track("first", obj({{"a", 1}})).produced && c->pending_install_code().empty());
  CHECK_THAT(c->track("second", Value()).produced);
  const auto events = queued_events(*c);
  CHECK_THAT(events.size() == 3);
  CHECK_THAT(events.size() == 3 && events[0].find("properties")->find("fr_install_code") == nullptr);
  CHECK_THAT(events.size() == 3 && str(events[1].find("properties")->find("fr_install_code")) == "7KQ2-M9XA4P" && events[1].find("properties")->find("a")->as_int() == 1);
  CHECK_THAT(events.size() == 3 && events[2].find("properties") == nullptr);
  CHECK_THAT(!c->set_install_code("bad") && c->pending_install_code().empty());
  CHECK_THAT(c->set_install_code("ZZZZZZZZZZ") && c->track("third", Value()).produced);
  const auto later = queued_events(*c);
  CHECK_THAT(later.size() == 4 && str(later[3].find("properties")->find("fr_install_code")) == "ZZZZZZZZZZ");

  // Geçersiz yapılandırma kodu hiç göndermez.
  g::Options invalid;
  invalid.install_code = "ILOU-ILOU-1";
  auto d = f.client(false, invalid);
  d->set_consent(consent(true));
  CHECK_THAT(d->pending_install_code().empty() && d->track("x", Value()).produced);
  CHECK_THAT(queued_events(*d)[0].find("properties") == nullptr);
}

int main(int argc, char** argv) {
  const std::string dir = argc > 1 ? argv[1] : ".";
  vector_tests(dir);
  test_persistence(dir);
  test_store_edge_cases(dir);
  test_contracts(dir);
  test_errors_and_session(dir);
  test_attribution(dir);
  test_bind_install(dir);
  test_install_code(dir);
  std::error_code ec;
  for (const char* name : {"persist", "edge", "limit", "contracts", "errors", "errors2", "session", "attr", "attr2", "attr3", "attr4", "bind", "install"}) std::filesystem::remove_all(dir + "/tmp_" + name, ec);
  std::printf("game_test: %d denetim, %d kaldı\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
