# Feralin C/C++ SDK (`feralin`) — UTP v1 istemcisi

Masaüstü, sunucu ve gömülü C/C++ uygulamalarından Feralin toplayıcısına (`services/collect`, `POST /v1/batch`) olay gönderir.
C++17 çekirdek, kararlı C API (`feralin.h`) ve CMake paketi. Dış JSON bağımlılığı yoktur. HTTP: Windows'ta WinHTTP, öteki sistemlerde libcurl; ikisi de istenmezse transport dışarıdan verilir.

## Durum (dürüst)

| Konu | Durum |
|---|---|
| Kod: `track`, `identify`, `set_consent`, `flush`, `close`, `status`, `track_revenue`, `group`, `set_user_properties`, `capture_error`, C API | Birim testleri geçti (`ctest`, WSL2 Ubuntu 24.04 g++ 13.3 ve libcurl; `feralin_signals_tests` ayrıca Windows MinGW g++ ile): `feralin_tests` 44, `feralin_signals_tests` 15, `feralin_transport_tests` 6 (gerçek yerel TCP sunucusu), `feralin_c_tests` 153 denetim |
| Gerçek `collect` ile uçtan uca | Windows + MinGW g++ + WinHTTP ile `scripts/sdk-e2e/run.mjs cpp` geçti: C++ ve C tüketicileri, 202, outbox, `fr_click`, izinsiz red, 401, idempotency |
| libcurl katmanı (Linux) | WSL2 Ubuntu 24.04, g++ 13.3, libcurl 8.5 ile derlendi; birim testleri ve yerel TCP sunucusu testleri geçti. Gerçek `collect` karşısında koşmadı. macOS ve MSVC denenmedi |
| Yayın | **`BLOCKED_EXTERNAL`.** Kanal: herkese açık depodaki Git etiketi `sdks/cpp/v<sürüm>` (<https://github.com/feralincom/sdk>) ve CMake `FetchContent`. Etiket henüz gönderilmedi; gönderim ve etiket site sahibinin onayını bekler. İmzalı sürüm (release) ve imza anahtarı yok |
| `track_revenue`, `group`, `set_user_properties`, `capture_error` | Birim testli; gerçek `collect` karşısında henüz koşmadı. Makbuz doğrulama sunucudadır (`BLOCKED_EXTERNAL`) |
| OTel tracing, kalıcı kuyruk, yakalanmamış istisna ve çökme yakalama | Yok. Kuyruk bellek içidir; süreç ölürse kaybolur |

## Kurulum

Registry yok; kaynaktan derlenir. İki yol var: Git etiketinden `FetchContent` ya da derleyip kurmak.

### Git etiketinden (FetchContent)

SDK herkese açık depoda `sdks/cpp` altındadır; sürüm etiketi `sdks/cpp/v0.1.0`. CMake 3.18+ gerekir (`SOURCE_SUBDIR`):

```cmake
include(FetchContent)
FetchContent_Declare(
  feralin
  GIT_REPOSITORY https://github.com/feralincom/sdk.git
  GIT_TAG        sdks/cpp/v0.1.0
  GIT_SHALLOW    TRUE
  SOURCE_SUBDIR  sdks/cpp)
FetchContent_MakeAvailable(feralin)
target_link_libraries(uygulamam PRIVATE feralin::feralin)
```

Etiket depoya gönderilmeden bu adım `GIT_TAG` bulunamadı hatası verir; yayımlanmış etiketler <https://github.com/feralincom/sdk/tags> sayfasındadır. Alt proje olarak eklendiğinde SDK testleri derlenmez. Çalışan örnek: `examples/fetchcontent/CMakeLists.txt` (yerel kopya için `-DFETCHCONTENT_SOURCE_DIR_FERALIN=<depo kökü>`).

### Derleyip kurmak

```bash
cmake -S sdks/cpp -B sdks/cpp/build -DCMAKE_BUILD_TYPE=Release
cmake --build sdks/cpp/build
cmake --install sdks/cpp/build --prefix /opt/feralin
```

Tüketici proje:

```cmake
find_package(feralin CONFIG REQUIRED)     # -DCMAKE_PREFIX_PATH=/opt/feralin
target_link_libraries(uygulamam PRIVATE feralin::feralin)
```

Seçenekler: `-DFERALIN_TRANSPORT=AUTO|WINHTTP|CURL|NONE`, `-DBUILD_SHARED_LIBS=ON` (yalnız C API dışa açılır), `-DFERALIN_BUILD_TESTS=OFF`. Linux'ta libcurl geliştirme paketi gerekir.

## En kısa örnek

```cpp
#include <feralin/feralin.hpp>

feralin::Options options;
options.project_key = "pk_live_...";                 // sk_ reddedilir
options.collect_url = "https://collect.example.com";
options.consent.analytics = true;                    // kullanıcıdan alınan izin; varsayılan kapalı

auto client = feralin::Client::create(options);      // geçersiz seçenekte nullptr
client->track("order_completed", {{"order_id", "ord_1"}, {"amount", 249.9}});
feralin::FlushResult result = client->close();       // kalan olayları en fazla 5 sn içinde gönderir
```

C:

```c
#include <feralin/feralin.h>

feralin_options options;
feralin_options_init(&options);
options.project_key = "pk_live_...";
options.collect_url = "https://collect.example.com";
options.consent = FERALIN_CONSENT_ANALYTICS;

feralin_client* client = NULL;
if (feralin_client_new(&options, &client) != FERALIN_OK) { /* feralin_last_error() */ }

feralin_props* props = feralin_props_new();
feralin_props_set_string(props, "order_id", "ord_1");
feralin_track(client, "order_completed", props, NULL, NULL);
feralin_props_free(props);
feralin_client_free(client);  /* kapatır, kalan olayları göndermeyi dener */
```

Çalıştırılabilir örnek: `examples/basic.cpp`.

SDK hataları istisna fırlatmaz; sonuç `Error` alanında (C'de durum kodu ve `feralin_last_error()`) döner. C sınırından istisna geçmez.

## Gelir, profil ve hata

```cpp
feralin::RevenueInput purchase;
purchase.transaction_id = "ord_1001";   // sunucu aynı işlemi ikinci kez saymaz
purchase.amount_minor = 4999;           // 49,99 TL: küçük birimde tam sayı
purchase.currency = "TRY";
purchase.receipt = feralin::Receipt{"google", purchase_token};  // isteğe bağlı
client->track_revenue(purchase);         // feralin_purchase; geçersiz girdide error.code == invalid_event

client->group("acme", {{"plan", "enterprise"}});          // fr_group
client->set_user_properties({{"tier", "gold"}});          // fr_user_properties

try {
  load_level();
} catch (const std::exception& error) {
  client->capture_error(error);          // fr_error: tür adı, temizlenmiş mesaj, parmak izi
}
```

- Gelir istemci beyanıdır: sunucu yalnız makbuz doğrulayıcısı onaylarsa `REAL_VERIFIED` sayar, aksi hâlde `ESTIMATED` kalır. `verified` hiçbir zaman gönderilmez.
- Profil: anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, en çok 50; kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad vb.), e-posta biçimli değer, nesne ve dizi düşer. Geçersiz `group_id` ya da geçerli özellik kalmaması hata değildir: olay üretilmez (`produced == false`).
- Hata: mesajdan URL, e-posta, UUID, rakamlı uzun belirteç ve 7+ rakamlı sayı çıkarılır, 200 karaktere kırpılır. C++ istisnası taşınabilir yığın izi taşımaz; çerçeve yoksa parmak izi tür ve rakamsız mesajdan kurulur. Kendi normalize çerçeveleriniz için `feralin::ErrorReport` verin. Süreç başına 20, aynı parmak izi için 3 olay; `Options::error_sample_rate` ve `Options::app_version`. C'de `feralin_capture_error(client, "IOError", message, FERALIN_ERROR_ORIGIN_HANDLED, 0, NULL, NULL)`.

## İzin

- Varsayılan kapalıdır. `consent.analytics` false iken `track` olay üretmez (`produced == false`, hata yok), ağ çağrısı olmaz.
- İzin çekilince bekleyen ve yeniden denenecek olaylar silinir.
- `consent.advertising` false iken `fr_click` özelliği olaydan çıkarılır.
- İzni kullanıcıdan almak ve saklamak uygulamanındır; SDK izin ekranı açmaz, kalıcı kayıt tutmaz.

## Teslim davranışı

- `202`: olaylar kuyruktan çıkar.
- `401` / `403`: anahtar geçersiz; **bütün kuyruk** atılır, uygulama düşmez.
- Öteki `4xx` (`429` hariç): yalnız o batch atılır.
- `5xx`, `429`, ağ hatası, zaman aşımı: olaylar kuyrukta kalır; batch aynı içerik ve aynı `Idempotency-Key` ile yeniden denenir, araya giren olaylar sonraki batch'e kalır. Üstel geri çekilme 1 sn → 30 sn, `Retry-After` en az o kadar bekletir. Açık `flush()` geri çekilmeyi beklemez.
- `Idempotency-Key`: sıralı `event_id` değerlerinin FNV-1a 64 özeti ve olay sayısı; bütün SDK'larla aynı.
- Yönlendirme izlenmez: proje anahtarı başka adrese taşınmaz.
- Yanıt gövdesi 64 KB ile sınırlıdır.

## Gizlilik

PII toplanmaz, cihaz veya donanım kimliği okunmaz, parmak izi yoktur. `tenant_id`, `project_id`, `verified` istemciden gönderilmez. Anahtar ve ham olay içeriği log kanalına yazılmaz. `user_id` uygulamanın kendi kimliğidir; e-posta veya ad vermeyin.

## Kendi transport'unuz

```cpp
class MyTransport final : public feralin::Transport {
 public:
  feralin::HttpResponse post(const feralin::HttpRequest& request) override;  // status 0: ağ hatası
};
options.transport = std::make_shared<MyTransport>();
```

C'de `feralin_options.transport` işlevi. `request.timeout_ms` sınırına uyulmalıdır; aksi halde `close()` çağrının bitmesini bekler.

## Desteklenmeyenler

- Kalıcı (diskte) kuyruk: süreç kapanırken gönderilemeyen olay kaybolur.
- Otomatik bağlam toplama: `locale`, ekran, sürüm gibi alanlar yalnız uygulama verirse gider.
- `attribution` ve `deeplink`: bu platformda uygulanmaz.
- `fork()` sonrası çocuk süreçte aynı istemciyi kullanmak: arka plan iş parçacığı kopyalanmaz.
- C++ başlığının DLL sınırından kullanımı: paylaşımlı derlemede yalnız C API dışa açıktır.

## Geliştirme

```bash
cmake -S sdks/cpp -B sdks/cpp/build -DFERALIN_WERROR=ON
cmake --build sdks/cpp/build
ctest --test-dir sdks/cpp/build --output-on-failure

DATABASE_URL='postgres://...test...' COLLECT_ADDR=127.0.0.1:4713 node scripts/sdk-e2e/run.mjs cpp
```

`include/feralin/wire.hpp` Unreal eklentisinde birebir kopyalıdır (`sdks/unreal/Feralin/Source/Feralin/Private/FeralinWire.hpp`). Bu dosyayı değiştirdiyseniz kopyalayın; `node sdks/unreal/tests/run.mjs` farkı yakalar. `tests/wire_cases.inc` iki SDK'da aynı bayt çıktısını sınar.
