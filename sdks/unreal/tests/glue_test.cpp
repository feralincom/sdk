// UFeralinSubsystem akışı: UE taklit başlıklarıyla (ue_stub.h). Gerçek motorda çalıştığını KANITLAMAZ; kendi kodumuzu sınar.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include "FeralinSettings.h"
#include "FeralinSubsystem.h"

#include "FeralinWire.hpp"

namespace {

int g_failures = 0;
int g_checks = 0;

#define CHECK_THAT(condition)                                            \
  do {                                                                   \
    ++g_checks;                                                          \
    if (!(condition)) {                                                  \
      ++g_failures;                                                      \
      std::printf("KALDI %s:%d: %s\n", __FILE__, __LINE__, #condition);  \
    }                                                                    \
  } while (false)

const char* const kKey = "pk_test_unreal_glue_01";

void configure(const char* key, const char* url, float interval) {
  UFeralinSettings* settings = MutableDefault<UFeralinSettings>();
  settings->ProjectKey = key;
  settings->CollectUrl = url;
  settings->FlushIntervalSeconds = interval;
  settings->BatchSize = 2;
  settings->QueueLimit = 10;
  settings->TimeoutSeconds = 7.0f;
  settings->bPersistQueue = false;
  settings->SessionTimeoutMinutes = 30;
  settings->AttributionApiUrl = "";
  settings->ProjectId = "";
  settings->bCaptureLogErrors = false;
  settings->InstallCode = "";
}

FHttpModule& http() { return FHttpModule::Get(); }

void reset_http() {
  http().created.clear();
  http().processed.clear();
  http().refuse_next = false;
}

void complete(std::size_t index, int status, const std::string& body, const std::string& retry_after = "") {
  auto response = std::make_shared<IHttpResponse>();
  response->Code = status;
  response->Body = body;
  response->RetryAfter = retry_after;
  response->Prepare();
  http().processed.at(index)->Delegate.Execute(FHttpResponsePtr(response), true);
}

void complete_network_error(std::size_t index) { http().processed.at(index)->Delegate.Execute(FHttpResponsePtr(), false); }

std::string ack(int accepted) { return "{\"batch_id\":\"01UEBATCH\",\"accepted\":" + std::to_string(accepted) + ",\"rejected\":0}"; }

FFeralinConsent consent(bool analytics, bool advertising = false) {
  FFeralinConsent out;
  out.bAnalytics = analytics;
  out.bAdvertising = advertising;
  return out;
}

void test_misconfigured_stays_off() {
  reset_http();
  FSubsystemCollectionBase collection;
  for (const char* key : {"sk_live_abcdefgh", "", "dev_key"}) {
    configure(key, "https://collect.example.test", 2.0f);
    UFeralinSubsystem subsystem;
    subsystem.Initialize(collection);
    CHECK_THAT(!FTSTicker::GetCoreTicker().HasTicker());
    subsystem.SetConsent(consent(true));
    CHECK_THAT(!subsystem.Track("order_completed", TMap<FString, FString>()));
    CHECK_THAT(subsystem.GetQueueLength() == 0);
    bool called = false;
    subsystem.OnFlushCompleted.Handlers.push_back([&called](const FFeralinFlushResult& result) {
      called = true;
      CHECK_THAT(!result.bSuccess);
    });
    subsystem.Flush();
    CHECK_THAT(called);
    subsystem.Deinitialize();
  }
  CHECK_THAT(http().created.empty());
  for (const std::string& line : stub_log_lines()) CHECK_THAT(line.find("sk_live_abcdefgh") == std::string::npos);
}

void test_track_flush_wire() {
  reset_http();
  FSubsystemCollectionBase collection;
  configure(kKey, "https://collect.example.test/", 0.0f);
  UFeralinSubsystem subsystem;
  subsystem.Initialize(collection);
  CHECK_THAT(!FTSTicker::GetCoreTicker().HasTicker());

  // Varsayılan izin kapalı: olay üretilmez, istek gitmez.
  TMap<FString, FString> properties;
  properties.Add("order_id", "ord_ue_1");
  properties.Add("fr_click", "clk_ue");
  CHECK_THAT(!subsystem.Track("order_completed", properties));
  CHECK_THAT(subsystem.GetQueueLength() == 0);

  subsystem.SetConsent(consent(true));
  CHECK_THAT(subsystem.GetConsent().bAnalytics && !subsystem.GetConsent().bAdvertising);
  CHECK_THAT(subsystem.Identify("user_ue"));
  CHECK_THAT(subsystem.SetAnonymousId("anon_ue"));
  TMap<FString, double> numbers;
  numbers.Add("amount", 12.5);
  CHECK_THAT(subsystem.TrackWithNumbers("order_completed", properties, numbers));
  CHECK_THAT(subsystem.GetQueueLength() == 1);
  CHECK_THAT(http().processed.empty());  // Track ağ çağrısı yapmaz

  int completed = 0;
  FFeralinFlushResult last;
  subsystem.OnFlushCompleted.Handlers.push_back([&](const FFeralinFlushResult& result) {
    ++completed;
    last = result;
  });
  subsystem.Flush();
  CHECK_THAT(http().processed.size() == 1);
  const auto& request = http().processed.at(0);
  CHECK_THAT(request->Url == "https://collect.example.test/v1/batch");
  CHECK_THAT(request->Verb == "POST");
  CHECK_THAT(request->Timeout == 7.0f);
  CHECK_THAT(request->header("X-Feralin-Project-Key") == kKey);
  CHECK_THAT(request->header("User-Agent") == "feralin-unreal/0.2.0");
  CHECK_THAT(request->header("Content-Type") == "application/json");
  CHECK_THAT(request->Body.find("\"platform\":\"unreal\"") != std::string::npos);
  CHECK_THAT(request->Body.find("\"sdk\":{\"name\":\"feralin-unreal\",\"version\":\"0.2.0\"}") != std::string::npos);
  CHECK_THAT(request->Body.find("\"occurred_at\":\"2026-11-03T07:20:00.123Z\"") != std::string::npos);
  CHECK_THAT(request->Body.find("\"user_id\":\"user_ue\"") != std::string::npos);
  CHECK_THAT(request->Body.find("\"anonymous_id\":\"anon_ue\"") != std::string::npos);
  CHECK_THAT(request->Body.find("\"amount\":12.5") != std::string::npos);
  CHECK_THAT(request->Body.find("fr_click") == std::string::npos);  // reklam izni yok
  CHECK_THAT(request->Body.find("verified") == std::string::npos);
  CHECK_THAT(completed == 0);  // yanıt gelmeden sonuç bildirilmez

  complete(0, 202, ack(1));
  CHECK_THAT(completed == 1);
  CHECK_THAT(last.bSuccess && last.HttpStatus == 202 && last.Accepted == 1 && last.Sent == 1 && last.Retained == 0);
  CHECK_THAT(last.BatchId == FString("01UEBATCH"));
  CHECK_THAT(subsystem.GetQueueLength() == 0);

  // Reklam izniyle fr_click gider.
  subsystem.SetConsent(consent(true, true));
  CHECK_THAT(subsystem.Track("order_completed", properties));
  subsystem.Flush();
  CHECK_THAT(http().processed.at(1)->Body.find("\"fr_click\":\"clk_ue\"") != std::string::npos);
  complete(1, 202, ack(1));

  // İzin çekilince kuyruk boşalır.
  CHECK_THAT(subsystem.Track("e", TMap<FString, FString>()));
  subsystem.SetConsent(consent(false));
  CHECK_THAT(subsystem.GetQueueLength() == 0);
  CHECK_THAT(!subsystem.GetConsent().bAnalytics);

  subsystem.Deinitialize();
}

void test_validation_and_json() {
  reset_http();
  FSubsystemCollectionBase collection;
  configure(kKey, "https://collect.example.test", 0.0f);
  UFeralinSubsystem subsystem;
  subsystem.Initialize(collection);
  subsystem.SetConsent(consent(true));
  CHECK_THAT(!subsystem.Track("BadName", TMap<FString, FString>()));
  TMap<FString, FString> bad;
  bad.Add("bad-key", "x");
  CHECK_THAT(!subsystem.Track("ok_event", bad));
  CHECK_THAT(!subsystem.TrackJson("ok_event", "{"));
  CHECK_THAT(!subsystem.TrackJson("ok_event", "[1]"));
  CHECK_THAT(subsystem.GetQueueLength() == 0);
  CHECK_THAT(subsystem.TrackJson("ok_event", "{\"level\":{\"id\":3,\"name\":\"ş\"}}"));
  CHECK_THAT(subsystem.TrackJson("ok_event", ""));
  CHECK_THAT(subsystem.GetQueueLength() == 2);
  subsystem.Flush();
  CHECK_THAT(http().processed.at(0)->Body.find("\"properties\":{\"level\":{\"id\":3,\"name\":\"ş\"}}") != std::string::npos);
  complete(0, 202, ack(2));
  subsystem.Deinitialize();
}

void test_retry_keeps_key_and_order() {
  reset_http();
  FSubsystemCollectionBase collection;
  configure(kKey, "https://collect.example.test", 0.0f);
  UFeralinSubsystem subsystem;
  subsystem.Initialize(collection);
  subsystem.SetConsent(consent(true));
  int completed = 0;
  FFeralinFlushResult last;
  subsystem.OnFlushCompleted.Handlers.push_back([&](const FFeralinFlushResult& result) {
    ++completed;
    last = result;
  });

  CHECK_THAT(subsystem.Track("first_event", TMap<FString, FString>()));
  subsystem.Flush();
  // Süren istek varken ikinci Flush yeni istek açmaz.
  subsystem.Flush();
  CHECK_THAT(http().processed.size() == 1);
  const std::string key = http().processed.at(0)->header("Idempotency-Key");

  complete_network_error(0);
  CHECK_THAT(completed == 1);
  CHECK_THAT(!last.bSuccess && last.bTemporaryFailure && last.HttpStatus == 0 && last.Retained == 1);
  CHECK_THAT(subsystem.GetQueueLength() == 1);

  // Araya giren olay anahtarı değiştirmez; geri çekilme açık Flush'ı engellemez.
  CHECK_THAT(subsystem.Track("second_event", TMap<FString, FString>()));
  subsystem.Flush();
  CHECK_THAT(http().processed.size() == 2);
  CHECK_THAT(http().processed.at(1)->header("Idempotency-Key") == key);
  CHECK_THAT(http().processed.at(1)->Body.find("first_event") != std::string::npos);
  CHECK_THAT(http().processed.at(1)->Body.find("second_event") == std::string::npos);

  complete(1, 503, "{}", "5");
  CHECK_THAT(completed == 2);
  CHECK_THAT(last.bTemporaryFailure && last.HttpStatus == 503);
  subsystem.Flush();
  CHECK_THAT(http().processed.at(2)->header("Idempotency-Key") == key);

  // Kabul sonrası aynı tur kalan olayı da gönderir.
  complete(2, 202, ack(1));
  CHECK_THAT(completed == 2);
  CHECK_THAT(http().processed.size() == 4);
  CHECK_THAT(http().processed.at(3)->header("Idempotency-Key") != key);
  CHECK_THAT(http().processed.at(3)->Body.find("second_event") != std::string::npos);
  complete(3, 202, ack(1));
  CHECK_THAT(completed == 3);
  CHECK_THAT(last.bSuccess && last.Sent == 2 && last.Accepted == 2 && last.Retained == 0);
  subsystem.Deinitialize();
}

void test_unauthorized_drops_queue() {
  reset_http();
  FSubsystemCollectionBase collection;
  configure(kKey, "https://collect.example.test", 0.0f);
  UFeralinSubsystem subsystem;
  subsystem.Initialize(collection);
  subsystem.SetConsent(consent(true));
  FFeralinFlushResult last;
  subsystem.OnFlushCompleted.Handlers.push_back([&](const FFeralinFlushResult& result) { last = result; });
  for (int i = 0; i < 5; ++i) subsystem.Track("e", TMap<FString, FString>());
  subsystem.Flush();
  complete(0, 401, "{\"title\":\"Yetkisiz\"}");
  CHECK_THAT(!last.bSuccess && !last.bTemporaryFailure && last.HttpStatus == 401 && last.Rejected == 5);
  CHECK_THAT(subsystem.GetQueueLength() == 0);
  CHECK_THAT(http().processed.size() == 1);
  CHECK_THAT(std::string(*last.Error).find(kKey) == std::string::npos);
  for (const std::string& line : stub_log_lines()) CHECK_THAT(line.find(kKey) == std::string::npos);
  subsystem.Deinitialize();
}

void test_ticker_respects_backoff_and_batch_size() {
  reset_http();
  FSubsystemCollectionBase collection;
  configure(kKey, "https://collect.example.test", 2.0f);
  UFeralinSubsystem subsystem;
  subsystem.Initialize(collection);
  CHECK_THAT(FTSTicker::GetCoreTicker().HasTicker());
  CHECK_THAT(FTSTicker::GetCoreTicker().Interval == 2.0f);
  subsystem.SetConsent(consent(true));

  // Boş kuyrukta istek yok.
  FTSTicker::GetCoreTicker().Fire();
  CHECK_THAT(http().processed.empty());

  subsystem.Track("a", TMap<FString, FString>());
  CHECK_THAT(http().processed.empty());
  FTSTicker::GetCoreTicker().Fire();
  CHECK_THAT(http().processed.size() == 1);
  // Geri çekilme: 1 sn dolmadan yeniden deneme yok.
  complete_network_error(0);
  FTSTicker::GetCoreTicker().Fire();
  CHECK_THAT(http().processed.size() == 1);
  FPlatformTime::Now() += 2.0;
  FTSTicker::GetCoreTicker().Fire();
  CHECK_THAT(http().processed.size() == 2);
  complete(1, 202, ack(1));
  CHECK_THAT(subsystem.GetQueueLength() == 0);

  // Batch boyutuna (2) ulaşan kuyruk aralığı beklemeden gönderilir.
  subsystem.Track("b", TMap<FString, FString>());
  CHECK_THAT(http().processed.size() == 2);
  subsystem.Track("c", TMap<FString, FString>());
  CHECK_THAT(http().processed.size() == 3);
  complete(2, 202, ack(2));

  // Kapanış: kalan olay için son istek açılır, ticker kaldırılır; geç yanıt çökertmez.
  subsystem.Track("d", TMap<FString, FString>());
  subsystem.Deinitialize();
  CHECK_THAT(!FTSTicker::GetCoreTicker().HasTicker());
  CHECK_THAT(http().processed.size() == 4);
  complete(3, 202, ack(1));
  CHECK_THAT(subsystem.GetQueueLength() == 0);
}

void test_refused_request_is_network_error() {
  reset_http();
  FSubsystemCollectionBase collection;
  configure(kKey, "https://collect.example.test", 0.0f);
  UFeralinSubsystem subsystem;
  subsystem.Initialize(collection);
  subsystem.SetConsent(consent(true));
  FFeralinFlushResult last;
  subsystem.OnFlushCompleted.Handlers.push_back([&](const FFeralinFlushResult& result) { last = result; });
  subsystem.Track("e", TMap<FString, FString>());
  http().refuse_next = true;
  subsystem.Flush();
  CHECK_THAT(last.bTemporaryFailure);
  CHECK_THAT(subsystem.GetQueueLength() == 1);
  subsystem.SetConsent(consent(false));
  subsystem.Deinitialize();
}

// v0.2.0 yüzeyi: gelir, reklam geliri, oyun olayları, hata, günlük, yaşam döngüsü, bağlantı, kalıcı şifreli kuyruk.
void test_game_surface_and_persistence() {
  reset_http();
  std::error_code ec;
  std::filesystem::remove_all("glue_queue", ec);
  std::filesystem::create_directories("glue_queue", ec);
  FSubsystemCollectionBase collection;
  configure(kKey, "https://collect.example.test/", 0.0f);
  UFeralinSettings* settings = MutableDefault<UFeralinSettings>();
  settings->bPersistQueue = true;
  settings->QueueDirectory = "glue_queue";
  settings->bCaptureLogErrors = true;
  settings->BatchSize = 100;
  settings->QueueLimit = 1000;
  {
    UFeralinSubsystem subsystem;
    subsystem.Initialize(collection);
    CHECK_THAT(FCoreDelegates::ApplicationWillEnterBackgroundDelegate.Count() == 1 && GLog->devices.size() == 1);
    subsystem.SetConsent(consent(true, true));
    TMap<FString, FString> none;
    CHECK_THAT(subsystem.TrackRevenue("tx1", 4999, "TRY", "gold", 1, EFeralinPurchaseType::Purchase, EFeralinReceiptProvider::Google, "tok_secret_receipt", none));
    CHECK_THAT(!subsystem.TrackRevenue("tx2", -5, "TRY", "", 1, EFeralinPurchaseType::Purchase, EFeralinReceiptProvider::None, "", none));
    CHECK_THAT(subsystem.TrackAdRevenue("admob", EFeralinAdFormat::Rewarded, 12500, "USD", "", EFeralinAdPrecision::Estimated, "", "", none));
    CHECK_THAT(subsystem.TrackLevelStart("l1", 1) && subsystem.TrackLevelComplete("l1", -1, 10, 5000) && subsystem.TrackLevelFail("l1", -1, -1, -1, "boss"));
    CHECK_THAT(!subsystem.TrackLevelStart("", -1) && !subsystem.TrackEconomySource("gem", 0));
    CHECK_THAT(subsystem.TrackEconomySource("gem", 5, "quest") && subsystem.TrackEconomySink("gem", 2) && subsystem.TrackRewardedAdShown("main") && subsystem.TrackRewardedAdComplete("main", "admob", 3, "gem"));
    CHECK_THAT(subsystem.TrackIapOfferShown("sku") && subsystem.TrackIapInitiated("sku", "", "tx1"));
    TMap<FString, FString> traits;
    traits.Add("size", "5");
    CHECK_THAT(subsystem.Group("clan", traits) && subsystem.SetUserProperties(traits));
    CHECK_THAT(subsystem.CaptureError("Boom", "mail ali@example.com", "A.B () (at x.cs:1)", true));
    // Motor günlüğü: Error kaydı fr_error olur, Warning olmaz.
    GLog->Emit("LogGame: kullanici hata", ELogVerbosity::Error, "LogGame");
    GLog->Emit("LogGame: uyari", ELogVerbosity::Warning, "LogGame");
    GLog->Emit("LogFeralin: kendi", ELogVerbosity::Error, "LogFeralin");
    subsystem.HandleDeepLink("https://shop.example.com/p?fr_click=clk1&secret=1");
    const int32 queued = subsystem.GetQueueLength();
    CHECK_THAT(queued == 16);
    // Arka plana geçişte gönderim denenir.
    FCoreDelegates::ApplicationWillEnterBackgroundDelegate.Broadcast();
    CHECK_THAT(http().processed.size() == 1);
    const std::string body = http().processed[0]->Body;
    CHECK_THAT(body.find("\"event_name\":\"feralin_purchase\"") != std::string::npos && body.find("\"event_name\":\"fr_ad_revenue\"") != std::string::npos);
    CHECK_THAT(body.find("\"event_name\":\"fr_error\"") != std::string::npos && body.find("\"event_name\":\"deep_link_opened\"") != std::string::npos);
    CHECK_THAT(body.find("\"verified\"") == std::string::npos && body.find("ali@example.com") == std::string::npos && body.find("secret=1") == std::string::npos);
    CHECK_THAT(body.find("\"session_id\":\"") != std::string::npos);
    // Yanıt gelmeden süreç kapanır: olaylar diskte şifreli kalır.
    http().processed.clear();
    subsystem.Deinitialize();
  }
  std::stringstream text;
  {
    // Açık dosya tutucusu Windows'ta sonraki silmeyi engeller: kapsam içinde kapatılır.
    std::ifstream disk("glue_queue/events.log", std::ios::binary);
    text << disk.rdbuf();
  }
  CHECK_THAT(text.str().find("enc1:") != std::string::npos && text.str().find("feralin_purchase") == std::string::npos && text.str().find("tok_secret_receipt") == std::string::npos);
  CHECK_THAT(GLog->devices.empty() && FCoreDelegates::ApplicationWillEnterBackgroundDelegate.Count() == 0);
  reset_http();
  {
    // Yeniden başlatma: aynı olaylar izin verilince geri yüklenir ve kabulden sonra diskten silinir.
    UFeralinSubsystem subsystem;
    subsystem.Initialize(collection);
    CHECK_THAT(subsystem.GetQueueLength() == 0);
    subsystem.SetConsent(consent(true, true));
    CHECK_THAT(subsystem.GetQueueLength() >= 16);
    subsystem.Flush();
    CHECK_THAT(http().processed.size() == 1);
    {
      // Gönderilen gövdedeki olay sayısı diskteki satır sayısına eşit olmalı.
      std::ifstream before("glue_queue/events.log", std::ios::binary);
      std::stringstream all;
      all << before.rdbuf();
      std::size_t lines = 0;
      for (const char c : all.str()) lines += c == '\n' ? 1 : 0;
      std::size_t events = 0;
      const std::string sent = http().processed[0]->Body;
      for (std::size_t at = sent.find("\"event_id\""); at != std::string::npos; at = sent.find("\"event_id\"", at + 1)) ++events;
      std::printf("  disk satir %zu, gonderilen %zu\n", lines, events);
    }
    complete(0, 202, ack(100));
    std::printf("  ack sonrasi kuyruk %d, dosya var mi %d\n", subsystem.GetQueueLength(), static_cast<int>(std::filesystem::exists("glue_queue/events.log")));
    subsystem.Flush();
    for (std::size_t i = 1; i < http().processed.size(); ++i) complete(i, 202, ack(100));
    CHECK_THAT(subsystem.GetQueueLength() == 0);
    std::ifstream after("glue_queue/events.log", std::ios::binary);
    std::stringstream rest;
    rest << after.rdbuf();
    if (!rest.str().empty()) std::printf("  kalan satir: %zu bayt, kuyruk %d\n", rest.str().size(), subsystem.GetQueueLength());
    CHECK_THAT(rest.str().empty());
    subsystem.Deinitialize();
  }
  // BindInstall: yapılandırma yoksa not_configured.
  {
    settings->AttributionApiUrl = "";
    UFeralinSubsystem subsystem;
    subsystem.Initialize(collection);
    FString status;
    subsystem.OnInstallBound.Handlers.push_back([&status](const FFeralinInstallBinding& binding) { status = binding.Status; });
    subsystem.SetConsent(consent(true, true));
    subsystem.BindInstall();
    CHECK_THAT(status == FString("not_configured"));
    subsystem.Deinitialize();
  }
  settings->bPersistQueue = false;
  settings->bCaptureLogErrors = false;
  settings->QueueDirectory = "";
  std::filesystem::remove_all("glue_queue", ec);
}

// Proje ayarındaki InstallCode ve SetInstallCode: kod yalnız ilk olayla gider.
void test_install_code_setting() {
  reset_http();
  FSubsystemCollectionBase collection;
  configure(kKey, "https://collect.example.test/", 0.0f);
  MutableDefault<UFeralinSettings>()->InstallCode = " 7KQ2-M9XA4P ";
  UFeralinSubsystem subsystem;
  subsystem.Initialize(collection);
  subsystem.SetConsent(consent(true));
  CHECK_THAT(subsystem.Track("first_event", TMap<FString, FString>()));
  CHECK_THAT(subsystem.Track("second_event", TMap<FString, FString>()));
  subsystem.Flush();
  CHECK_THAT(http().processed.size() == 1);
  if (!http().processed.empty()) {
    const std::string body = http().processed[0]->Body;
    const std::size_t first = body.find("\"fr_install_code\":\"7KQ2-M9XA4P\"");
    CHECK_THAT(first != std::string::npos && body.find("fr_install_code", first + 2) == std::string::npos);
    CHECK_THAT(first != std::string::npos && first < body.find("\"event_name\":\"second_event\""));
    complete(0, 202, ack(2));
  }
  CHECK_THAT(!subsystem.SetInstallCode("ILOU"));
  CHECK_THAT(subsystem.SetInstallCode("ABCDEFGHJK"));
  CHECK_THAT(subsystem.Track("third_event", TMap<FString, FString>()));
  subsystem.Flush();
  CHECK_THAT(http().processed.size() == 2 && http().processed.back()->Body.find("\"fr_install_code\":\"ABCDEFGHJK\"") != std::string::npos);
  subsystem.Deinitialize();
  MutableDefault<UFeralinSettings>()->InstallCode = "";
}

}  // namespace

int main() {
  test_game_surface_and_persistence();
  test_misconfigured_stays_off();
  test_track_flush_wire();
  test_validation_and_json();
  test_retry_keeps_key_and_order();
  test_unauthorized_drops_queue();
  test_ticker_respects_backoff_and_batch_size();
  test_refused_request_is_network_error();
  test_install_code_setting();
  std::printf("%d denetim, %d kaldı\n", g_checks, g_failures);
  return g_failures == 0 ? 0 : 1;
}
