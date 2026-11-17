/* Feralin C/C++ SDK kararlı C API'si. UTP v1 olaylarını POST {collect}/v1/batch ile gönderir.
 *
 * ABI sözü: ana sürüm içinde bu dosyadaki işlev imzaları ve yapı düzenleri değişmez; yeni alan yalnız struct_size taşıyan
 * yapıların sonuna eklenir. İstisna bu sınırdan dışarı çıkmaz. Bütün işlevler iş parçacığı güvenlidir; feralin_client_free
 * tek başına çağrılmalıdır.
 *
 * İzin: varsayılan kapalıdır. FERALIN_CONSENT_ANALYTICS yokken olay üretilmez; FERALIN_CONSENT_ADVERTISING yokken
 * fr_click çıkarılır. tenant_id, project_id ve verified istemciden asla gönderilmez. */
#ifndef FERALIN_H
#define FERALIN_H

#include <stddef.h>
#include <stdint.h>

/* CMake proje sürümü de bu satırdan okunur; sürümün tek kaynağıdır. */
#define FERALIN_SDK_VERSION "0.1.0"

#if defined(_WIN32) && defined(FERALIN_SHARED)
#if defined(FERALIN_BUILDING)
#define FERALIN_API __declspec(dllexport)
#else
#define FERALIN_API __declspec(dllimport)
#endif
#elif defined(__GNUC__)
#define FERALIN_API __attribute__((visibility("default")))
#else
#define FERALIN_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct feralin_client feralin_client;
typedef struct feralin_props feralin_props;

typedef enum feralin_status {
  FERALIN_OK = 0,
  FERALIN_ERR_CONFIGURATION = 1, /* geçersiz anahtar, adres veya seçenek */
  FERALIN_ERR_INVALID_EVENT = 2, /* ad, özellik veya kimlik UTP v1 kurallarına uymuyor */
  FERALIN_ERR_CLOSED = 3,        /* feralin_close sonrası çağrı */
  FERALIN_ERR_REJECTED = 4,      /* 4xx (429 hariç): olaylar kalıcı olarak atıldı */
  FERALIN_ERR_TEMPORARY = 5,     /* 5xx, 429 veya ağ: olaylar kuyrukta, aynı Idempotency-Key ile yeniden denenecek */
  FERALIN_ERR_INTERNAL = 6       /* bellek yetersizliği, iş parçacığı açılamadı veya NULL argüman */
} feralin_status;

#define FERALIN_CONSENT_ANALYTICS 1u
#define FERALIN_CONSENT_ADVERTISING 2u
#define FERALIN_CONSENT_PERSONALIZATION 4u
#define FERALIN_CONSENT_SESSION_REPLAY 8u

typedef struct feralin_http_header {
  const char* name;
  const char* value;
} feralin_http_header;

typedef struct feralin_http_request {
  const char* url;
  const char* body;
  size_t body_length;
  const feralin_http_header* headers;
  size_t header_count;
  int timeout_ms;
} feralin_http_request;

/* body tamponu SDK'ya aittir; transport en fazla body_capacity bayt yazar ve body_length değerini ayarlar. */
typedef struct feralin_http_response {
  int status;
  char* body;
  size_t body_capacity;
  size_t body_length;
  int retry_after_seconds; /* başlık yoksa 0 */
} feralin_http_response;

/* HTTP yanıtı alındıysa (hata kodları dahil) 0, ağ hatası veya zaman aşımında 0 dışı döner.
 * Herhangi bir iş parçacığından çağrılabilir ve request->timeout_ms sınırına uymalıdır. */
typedef int (*feralin_transport_fn)(void* user_data, const feralin_http_request* request, feralin_http_response* response);

#define FERALIN_LOG_DEBUG 0
#define FERALIN_LOG_WARNING 1
#define FERALIN_LOG_ERROR 2

/* Proje anahtarı ve ham olay içeriği bu kanala yazılmaz. */
typedef void (*feralin_log_fn)(void* user_data, int level, const char* message);

/* Saat enjeksiyonu: UTC epoch milisaniye (testler için). */
typedef int64_t (*feralin_now_fn)(void* user_data);

typedef struct feralin_options {
  size_t struct_size;
  const char* project_key;  /* zorunlu; pk_ ile başlamalı, sk_ reddedilir */
  const char* collect_url;  /* zorunlu; http(s) kök adresi */
  unsigned int consent;     /* FERALIN_CONSENT_* bit maskesi; varsayılan 0 */
  int flush_interval_ms;    /* varsayılan 2000; 0 veya negatif arka plan göndericiyi kapatır */
  int batch_size;           /* varsayılan 100, en fazla 500 */
  int queue_limit;          /* varsayılan 1000; aşılırsa en eski olay atılır */
  int timeout_ms;           /* varsayılan 10000 */
  feralin_transport_fn transport; /* NULL: Windows'ta WinHTTP, öteki sistemlerde libcurl */
  void* transport_user_data;
  feralin_log_fn logger;
  void* logger_user_data;
  feralin_now_fn now_ms;
  void* now_user_data;
  /* Sonradan eklenen alanlar struct_size ile okunur; eski yapıda varsayılan geçerlidir. */
  const char* app_version;  /* fr_error app_version alanı, en çok 32 karakter; NULL veya boş: gönderilmez */
  double error_sample_rate; /* fr_error örnekleme oranı 0..1; feralin_options_init 1 yazar */
} feralin_options;

/* Bütün dize alanları isteğe bağlıdır (NULL veya boş: gönderilmez). */
typedef struct feralin_track_options {
  size_t struct_size;
  const char* user_id; /* müşteri uygulamasının kendi kimliği; PII olmamalı */
  const char* anonymous_id;
  const char* session_id;
  int has_occurred_at;
  int64_t occurred_at_ms;
  const char* page_url;
  const char* page_title;
  const char* referrer;
  const char* locale;
  const char* timezone;
  const char* app_version;
  const char* app_build;
  int screen_width;  /* genişlik ve yükseklik birlikte > 0 ise gönderilir */
  int screen_height;
} feralin_track_options;

/* feralin_purchase girdisi (trackRevenue sözleşmesi). İstemci beyanıdır: verified hiçbir zaman gönderilmez; sunucu yalnız
 * makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar. feralin_revenue_init ile başlatılmalıdır. */
typedef struct feralin_revenue {
  size_t struct_size;
  const char* transaction_id;   /* zorunlu, 1..128 */
  int64_t amount_minor;         /* küçük birimde satır toplamı (49,99 TL -> 4999), 0..2^53-1; abonelik iptalinde 0 */
  const char* currency;         /* zorunlu, ISO 4217 üç büyük harf */
  const char* product_id;       /* NULL veya boş: gönderilmez; en çok 128 */
  int quantity;                 /* 0..100000; feralin_revenue_init 1 yazar */
  const char* purchase_type;    /* NULL: purchase; subscription_start, subscription_renew, subscription_cancel */
  const char* receipt_provider; /* NULL: makbuz yok; apple, google veya stripe */
  const char* receipt_token;    /* receipt_provider verildiyse zorunlu, 1..8192 */
  const feralin_props* properties; /* NULL olabilir; verified ve türevleri düşer */
} feralin_revenue;

#define FERALIN_ERROR_ORIGIN_HANDLED 0  /* yakalanan (try/catch) hata */
#define FERALIN_ERROR_ORIGIN_MANUAL 1   /* uygulamanın elle kurduğu rapor */
#define FERALIN_ERROR_ORIGIN_UNCAUGHT 2 /* yakalanmamış hata (ör. terminate işleyicisi) */

typedef struct feralin_track_result {
  int produced;        /* izin yoksa 0: olay üretilmedi, hata da yok */
  char event_id[27];   /* 26 karakter ULID + NUL */
} feralin_track_result;

typedef struct feralin_flush_result {
  int sent;
  int accepted;
  int rejected;
  int retained;
  int http_status;     /* 0: ağ hatası veya istek yapılmadı */
  char batch_id[65];   /* sunucunun verdiği batch_id; yoksa boş */
  char error[256];     /* hata yoksa boş */
} feralin_flush_result;

FERALIN_API const char* feralin_version(void);
FERALIN_API const char* feralin_status_name(feralin_status status);
/* Bu iş parçacığında son başarısız çağrının açıklaması; proje anahtarını içermez. */
FERALIN_API const char* feralin_last_error(void);

FERALIN_API void feralin_options_init(feralin_options* options);
FERALIN_API void feralin_track_options_init(feralin_track_options* options);
FERALIN_API void feralin_revenue_init(feralin_revenue* revenue);

FERALIN_API feralin_status feralin_client_new(const feralin_options* options, feralin_client** out_client);
/* Kapatılmadıysa en fazla 5 sn kalan olayları göndermeyi dener, sonra serbest bırakır. NULL güvenlidir. */
FERALIN_API void feralin_client_free(feralin_client* client);

/* analytics biti kalkarsa bekleyen olaylar atılır. */
FERALIN_API feralin_status feralin_set_consent(feralin_client* client, unsigned int consent);
/* Sonraki olaylar için varsayılan user_id. NULL veya boş dize varsayılanı kaldırır. */
FERALIN_API feralin_status feralin_identify(feralin_client* client, const char* user_id);
/* Olayı doğrular ve kuyruğa ekler; ağ çağrısı yapmaz. properties ve options NULL olabilir. out_result NULL olabilir. */
FERALIN_API feralin_status feralin_track(feralin_client* client, const char* event_name, const feralin_props* properties,
                                         const feralin_track_options* options, feralin_track_result* out_result);
/* feralin_purchase olayı. Sözleşme dışı girdide FERALIN_ERR_INVALID_EVENT döner, olay üretilmez. */
FERALIN_API feralin_status feralin_track_revenue(feralin_client* client, const feralin_revenue* revenue, const feralin_track_options* options,
                                                 feralin_track_result* out_result);
/* fr_group olayı: group_id 1-128 karakter, @ ve kontrol karakteri içermez; geçersizse FERALIN_OK ve produced=0 (olay yok).
 * traits NULL olabilir; kişisel veriye benzeyen anahtar ve sınır dışı değer düşer. */
FERALIN_API feralin_status feralin_group(feralin_client* client, const char* group_id, const feralin_props* traits, const feralin_track_options* options,
                                         feralin_track_result* out_result);
/* fr_user_properties olayı; geçerli özellik kalmazsa FERALIN_OK ve produced=0. */
FERALIN_API feralin_status feralin_set_user_properties(feralin_client* client, const feralin_props* properties, const feralin_track_options* options,
                                                       feralin_track_result* out_result);
/* fr_error olayı. Ham yığın izi gönderilmez: tür adı (en çok 64), temizlenmiş mesaj (URL, e-posta, UUID, belirteç ve uzun sayı
 * çıkar; en çok 200) ve parmak izi. origin FERALIN_ERROR_ORIGIN_*. Süreç başına 20, parmak izi başına 3 olay; sınıra
 * takılırsa FERALIN_OK ve produced=0. error_type NULL veya boş: "Error". */
FERALIN_API feralin_status feralin_capture_error(feralin_client* client, const char* error_type, const char* message, int origin, int fatal,
                                                 const feralin_track_options* options, feralin_track_result* out_result);
/* Kuyruktaki olayları batch'ler hâlinde gönderir; geri çekilme beklemez. out_result NULL olabilir. */
FERALIN_API feralin_status feralin_flush(feralin_client* client, feralin_flush_result* out_result);
/* Arka plan göndericiyi durdurur, kalan olayları en fazla timeout_ms içinde gönderir. İkinci çağrı boş sonuç döner. */
FERALIN_API feralin_status feralin_close(feralin_client* client, int timeout_ms, feralin_flush_result* out_result);
FERALIN_API size_t feralin_queue_length(feralin_client* client);
FERALIN_API int64_t feralin_dropped_count(feralin_client* client);

/* Olay özellikleri. Aynı anahtar yeniden verilirse son değer geçerlidir. */
FERALIN_API feralin_props* feralin_props_new(void);
FERALIN_API void feralin_props_free(feralin_props* properties);
FERALIN_API feralin_status feralin_props_set_string(feralin_props* properties, const char* key, const char* value);
FERALIN_API feralin_status feralin_props_set_int(feralin_props* properties, const char* key, int64_t value);
FERALIN_API feralin_status feralin_props_set_double(feralin_props* properties, const char* key, double value);
FERALIN_API feralin_status feralin_props_set_bool(feralin_props* properties, const char* key, int value);
/* value_json geçerli JSON olmalıdır (iç içe nesne ve dizi için). */
FERALIN_API feralin_status feralin_props_set_json(feralin_props* properties, const char* key, const char* value_json);

#ifdef __cplusplus
}
#endif

#endif /* FERALIN_H */
