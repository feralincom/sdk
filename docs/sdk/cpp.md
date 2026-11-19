<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# C / C++ native: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/cpp/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | C++ |
| Paket | `feralin` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/cpp` |
| Registry | CMake FetchContent + Git etiketi: **PUBLISHED** (sonraki adım: imzalı sürüm (imza anahtarı yok); paket yöneticisi kayıtları (vcpkg, Conan) yapılmadı) |
| Derleme | `node scripts/sdk-dry-run/cmake.mjs sdks/cpp build` |
| Test | `node scripts/sdk-dry-run/cmake.mjs sdks/cpp test` |

## Kurulum

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

```bash
cmake -S sdks/cpp -B sdks/cpp/build -DCMAKE_BUILD_TYPE=Release
cmake --build sdks/cpp/build
cmake --install sdks/cpp/build --prefix /opt/feralin
```

```cmake
find_package(feralin CONFIG REQUIRED)     # -DCMAKE_PREFIX_PATH=/opt/feralin
target_link_libraries(uygulamam PRIVATE feralin::feralin)
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız) |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil) |
| consent | SUPPORTED (yayınsız; istemci düzeyinde) |
| identity | PARTIAL (identify; group → fr_group, set_user_properties → fr_user_properties, C API dahil; ctest testli; reset yok) |
| attribution | N/A |
| deeplink | N/A |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL; ctest testli, gerçek toplayıcı e2e yok) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; ctest testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS | Windows MinGW g++ 16.1 (WinHTTP, statik ve DLL) ve WSL2 Ubuntu 24.04 g++ 13.3 (libcurl 8.5, statik ve .so) -Werror ile derlendi. MSVC ve macOS denenmedi. |
| test | PASS | ctest: feralin_tests 44, feralin_transport_tests 6 (gerçek yerel TCP sunucusu), feralin_c_tests 99 denetim; Windows ve WSL2'de ayrı ayrı geçti. |
| registry | PASS | Git etiketi sdks/cpp/v0.1.0 yayında (herkese açık depo commit 84b5c99, açıklamalı etiket (18 Kasım 2026, site sahibinin onayı)); imzasız. verify-git-install.mjs --remote: GEÇTİ (FetchContent GIT_TAG sdks/cpp/v0.1.0 SOURCE_SUBDIR sdks/cpp, feralin 0.1.0 indirildi, örnek derlendi). |
| clean_install | PASS | cmake --install ile ayrı öneke kuruldu, boş dizindeki tüketici find_package(feralin) ile derlendi. CMake olmayan yol g++ ile de geçti. Registry'den kurulum yok. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs cpp (Windows, WinHTTP): C++ ve C tüketicileri; 202, outbox, fr_click, izinsiz red, 401, idempotency; 12 outbox denetimi. libcurl gerçek toplayıcıya karşı koşmadı, yalnız yerel TCP sunucusuna karşı sınandı. |
| documentation | PASS | docs/sdk/cpp.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
