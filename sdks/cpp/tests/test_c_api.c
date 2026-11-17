/* C API testleri. Bu dosya bilinçli olarak saf C'dir: feralin.h başlığının C derleyicisinden geçtiğini de kanıtlar. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "feralin/feralin.h"

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(condition)                                                     \
  do {                                                                       \
    ++g_checks;                                                              \
    if (!(condition)) {                                                      \
      ++g_failures;                                                          \
      printf("KALDI %s:%d: %s\n", __FILE__, __LINE__, #condition);           \
    }                                                                        \
  } while (0)

typedef struct fake_collector {
  int next_status;
  int network_error;
  int calls;
  int retry_after;
  char last_key[128];
  char last_project_key[128];
  char last_body[8192];
} fake_collector;

static int fake_transport(void* user_data, const feralin_http_request* request, feralin_http_response* response) {
  fake_collector* collector = (fake_collector*)user_data;
  static const char ack[] = "{\"batch_id\":\"01CAPI\",\"accepted\":1,\"rejected\":0}";
  size_t i;
  ++collector->calls;
  for (i = 0; i < request->header_count; ++i) {
    if (strcmp(request->headers[i].name, "Idempotency-Key") == 0) {
      strncpy(collector->last_key, request->headers[i].value, sizeof(collector->last_key) - 1);
    }
    if (strcmp(request->headers[i].name, "X-Feralin-Project-Key") == 0) {
      strncpy(collector->last_project_key, request->headers[i].value, sizeof(collector->last_project_key) - 1);
    }
  }
  if (request->body_length < sizeof(collector->last_body)) {
    memcpy(collector->last_body, request->body, request->body_length);
    collector->last_body[request->body_length] = '\0';
  }
  if (collector->network_error) return 1;
  response->status = collector->next_status;
  response->retry_after_seconds = collector->retry_after;
  if (collector->next_status == 202) {
    memcpy(response->body, ack, sizeof(ack) - 1);
    response->body_length = sizeof(ack) - 1;
  }
  return 0;
}

static int64_t fixed_now(void* user_data) {
  (void)user_data;
  return 1793690400123LL;
}

static feralin_client* make_client(fake_collector* collector, unsigned int consent) {
  feralin_options options;
  feralin_client* client = NULL;
  feralin_options_init(&options);
  options.project_key = "pk_test_c_api_0001";
  options.collect_url = "https://collect.example.test/";
  options.consent = consent;
  options.flush_interval_ms = 0;
  options.transport = fake_transport;
  options.transport_user_data = collector;
  options.now_ms = fixed_now;
  CHECK(feralin_client_new(&options, &client) == FERALIN_OK);
  CHECK(client != NULL);
  return client;
}

static void test_config(void) {
  feralin_options options;
  feralin_client* client = (feralin_client*)&options;
  feralin_options_init(&options);
  CHECK(options.struct_size == sizeof(options));
  CHECK(options.batch_size == 100 && options.queue_limit == 1000 && options.timeout_ms == 10000 && options.flush_interval_ms == 2000);
  CHECK(options.consent == 0);

  options.project_key = "sk_live_abcdefgh";
  options.collect_url = "https://collect.example.test";
  CHECK(feralin_client_new(&options, &client) == FERALIN_ERR_CONFIGURATION);
  CHECK(client == NULL);
  CHECK(strstr(feralin_last_error(), "gizli anahtar") != NULL);
  CHECK(strstr(feralin_last_error(), "sk_live_abcdefgh") == NULL);

  options.project_key = NULL;
  CHECK(feralin_client_new(&options, &client) == FERALIN_ERR_CONFIGURATION);
  options.project_key = "pk_test_c_api_0001";
  options.collect_url = "ftp://x";
  CHECK(feralin_client_new(&options, &client) == FERALIN_ERR_CONFIGURATION);

  /* feralin_options_init atlandıysa çökmez. */
  memset(&options, 0, sizeof(options));
  CHECK(feralin_client_new(&options, &client) == FERALIN_ERR_CONFIGURATION);
  CHECK(feralin_client_new(NULL, &client) == FERALIN_ERR_INTERNAL);

  CHECK(strcmp(feralin_version(), FERALIN_SDK_VERSION) == 0);
  CHECK(strcmp(feralin_status_name(FERALIN_ERR_REJECTED), "FERALIN_ERR_REJECTED") == 0);
}

static void test_null_safety(void) {
  feralin_client_free(NULL);
  feralin_props_free(NULL);
  CHECK(feralin_track(NULL, "x", NULL, NULL, NULL) == FERALIN_ERR_INTERNAL);
  CHECK(feralin_flush(NULL, NULL) == FERALIN_ERR_INTERNAL);
  CHECK(feralin_queue_length(NULL) == 0);
  CHECK(feralin_props_set_string(NULL, "a", "b") == FERALIN_ERR_INTERNAL);
}

static void test_track_and_flush(void) {
  fake_collector collector;
  feralin_client* client;
  feralin_props* properties = feralin_props_new();
  feralin_track_options track_options;
  feralin_track_result event;
  feralin_flush_result result;
  memset(&collector, 0, sizeof(collector));
  collector.next_status = 202;
  client = make_client(&collector, FERALIN_CONSENT_ANALYTICS | FERALIN_CONSENT_ADVERTISING);

  CHECK(feralin_props_set_string(properties, "order_id", "ord_ş") == FERALIN_OK);
  CHECK(feralin_props_set_int(properties, "items", 2) == FERALIN_OK);
  CHECK(feralin_props_set_double(properties, "amount", 12.5) == FERALIN_OK);
  CHECK(feralin_props_set_bool(properties, "gift", 1) == FERALIN_OK);
  CHECK(feralin_props_set_json(properties, "tags", "[\"a\",{\"b\":1}]") == FERALIN_OK);
  CHECK(feralin_props_set_json(properties, "bad", "{") == FERALIN_ERR_INVALID_EVENT);
  CHECK(feralin_props_set_string(properties, "fr_click", "clk") == FERALIN_OK);

  feralin_track_options_init(&track_options);
  track_options.user_id = "user_c";
  track_options.locale = "tr-TR";
  track_options.screen_width = 800;
  track_options.screen_height = 600;
  track_options.app_version = "2.0";
  CHECK(feralin_track(client, "order_completed", properties, &track_options, &event) == FERALIN_OK);
  CHECK(event.produced == 1);
  CHECK(strlen(event.event_id) == 26);
  CHECK(feralin_queue_length(client) == 1);

  CHECK(feralin_flush(client, &result) == FERALIN_OK);
  CHECK(result.http_status == 202 && result.sent == 1 && result.accepted == 1 && result.retained == 0);
  CHECK(strcmp(result.batch_id, "01CAPI") == 0);
  CHECK(result.error[0] == '\0');
  CHECK(strcmp(collector.last_project_key, "pk_test_c_api_0001") == 0);
  CHECK(strstr(collector.last_body, "\"platform\":\"cpp\"") != NULL);
  CHECK(strstr(collector.last_body, "\"occurred_at\":\"2026-11-03T07:20:00.123Z\"") != NULL);
  CHECK(strstr(collector.last_body, "\"order_id\":\"ord_ş\"") != NULL);
  CHECK(strstr(collector.last_body, "\"items\":2") != NULL);
  CHECK(strstr(collector.last_body, "\"amount\":12.5") != NULL);
  CHECK(strstr(collector.last_body, "\"gift\":true") != NULL);
  CHECK(strstr(collector.last_body, "\"tags\":[\"a\",{\"b\":1}]") != NULL);
  CHECK(strstr(collector.last_body, "\"fr_click\":\"clk\"") != NULL);
  CHECK(strstr(collector.last_body, "\"user_id\":\"user_c\"") != NULL);
  CHECK(strstr(collector.last_body, "\"context\":{\"locale\":\"tr-TR\",\"screen\":{\"width\":800,\"height\":600},\"app\":{\"version\":\"2.0\"}}") != NULL);
  CHECK(strstr(collector.last_body, "verified") == NULL);

  feralin_props_free(properties);
  feralin_client_free(client);
}

static void test_consent(void) {
  fake_collector collector;
  feralin_client* client;
  feralin_props* properties = feralin_props_new();
  feralin_track_result event;
  feralin_flush_result result;
  memset(&collector, 0, sizeof(collector));
  collector.next_status = 202;
  client = make_client(&collector, 0);

  CHECK(feralin_track(client, "page_view", NULL, NULL, &event) == FERALIN_OK);
  CHECK(event.produced == 0 && event.event_id[0] == '\0');
  CHECK(feralin_queue_length(client) == 0);
  CHECK(feralin_flush(client, &result) == FERALIN_OK);
  CHECK(collector.calls == 0 && result.sent == 0);

  /* Reklam izni yok: fr_click çıkarılır. */
  CHECK(feralin_set_consent(client, FERALIN_CONSENT_ANALYTICS) == FERALIN_OK);
  feralin_props_set_string(properties, "fr_click", "clk");
  feralin_props_set_string(properties, "order_id", "o1");
  CHECK(feralin_track(client, "order_completed", properties, NULL, &event) == FERALIN_OK);
  CHECK(feralin_flush(client, &result) == FERALIN_OK);
  CHECK(strstr(collector.last_body, "fr_click") == NULL);
  CHECK(strstr(collector.last_body, "\"order_id\":\"o1\"") != NULL);

  /* İzin çekilince bekleyen olay atılır. */
  CHECK(feralin_track(client, "e", NULL, NULL, &event) == FERALIN_OK);
  CHECK(feralin_queue_length(client) == 1);
  CHECK(feralin_set_consent(client, 0) == FERALIN_OK);
  CHECK(feralin_queue_length(client) == 0);

  feralin_props_free(properties);
  feralin_client_free(client);
}

static void test_failures(void) {
  fake_collector collector;
  feralin_client* client;
  feralin_track_result first;
  feralin_track_result second;
  feralin_flush_result result;
  char key[128];
  memset(&collector, 0, sizeof(collector));
  client = make_client(&collector, FERALIN_CONSENT_ANALYTICS);

  CHECK(feralin_track(client, "BadName", NULL, NULL, NULL) == FERALIN_ERR_INVALID_EVENT);
  CHECK(strlen(feralin_last_error()) > 0);
  CHECK(feralin_track(client, NULL, NULL, NULL, NULL) == FERALIN_ERR_INVALID_EVENT);

  /* Ağ hatası: kuyrukta kalır, aynı Idempotency-Key ile yeniden denenir. */
  collector.network_error = 1;
  CHECK(feralin_track(client, "first_event", NULL, NULL, &first) == FERALIN_OK);
  CHECK(feralin_flush(client, &result) == FERALIN_ERR_TEMPORARY);
  CHECK(result.http_status == 0 && result.retained == 1);
  CHECK(result.error[0] != '\0');
  strcpy(key, collector.last_key);
  CHECK(feralin_track(client, "second_event", NULL, NULL, &second) == FERALIN_OK);

  collector.network_error = 0;
  collector.next_status = 503;
  collector.retry_after = 3;
  CHECK(feralin_flush(client, &result) == FERALIN_ERR_TEMPORARY);
  CHECK(result.http_status == 503);
  CHECK(strcmp(collector.last_key, key) == 0);
  CHECK(strstr(collector.last_body, first.event_id) != NULL);
  CHECK(strstr(collector.last_body, second.event_id) == NULL);

  collector.next_status = 202;
  CHECK(feralin_flush(client, &result) == FERALIN_OK);
  CHECK(feralin_queue_length(client) == 0);

  /* 401: kuyruk atılır, süreç düşmez. */
  CHECK(feralin_track(client, "e", NULL, NULL, NULL) == FERALIN_OK);
  collector.next_status = 401;
  CHECK(feralin_flush(client, &result) == FERALIN_ERR_REJECTED);
  CHECK(result.http_status == 401 && result.rejected == 1);
  CHECK(feralin_queue_length(client) == 0);
  CHECK(strstr(result.error, "pk_test_c_api_0001") == NULL);

  /* close sonrası. */
  collector.next_status = 202;
  CHECK(feralin_close(client, 1000, &result) == FERALIN_OK);
  CHECK(feralin_track(client, "late", NULL, NULL, NULL) == FERALIN_ERR_CLOSED);
  CHECK(feralin_flush(client, &result) == FERALIN_ERR_CLOSED);
  CHECK(feralin_close(client, 1000, &result) == FERALIN_OK);
  feralin_client_free(client);
}

static int g_log_calls = 0;
static int g_log_leak = 0;

static void capture_log(void* user_data, int level, const char* message) {
  (void)user_data;
  (void)level;
  ++g_log_calls;
  if (strstr(message, "pk_test_c_api_0001") != NULL) g_log_leak = 1;
}

static void test_logger_and_queue_limit(void) {
  fake_collector collector;
  feralin_options options;
  feralin_client* client = NULL;
  memset(&collector, 0, sizeof(collector));
  collector.next_status = 202;
  feralin_options_init(&options);
  options.project_key = "pk_test_c_api_0001";
  options.collect_url = "http://collect.example.test";
  options.consent = FERALIN_CONSENT_ANALYTICS;
  options.flush_interval_ms = 0;
  options.queue_limit = 2;
  options.transport = fake_transport;
  options.transport_user_data = &collector;
  options.logger = capture_log;
  CHECK(feralin_client_new(&options, &client) == FERALIN_OK);
  CHECK(feralin_track(client, "a", NULL, NULL, NULL) == FERALIN_OK);
  CHECK(feralin_track(client, "b", NULL, NULL, NULL) == FERALIN_OK);
  CHECK(feralin_track(client, "c", NULL, NULL, NULL) == FERALIN_OK);
  CHECK(feralin_queue_length(client) == 2);
  CHECK(feralin_dropped_count(client) == 1);
  CHECK(g_log_calls >= 1);
  CHECK(g_log_leak == 0);
  CHECK(feralin_identify(client, "user") == FERALIN_OK);
  CHECK(feralin_identify(client, NULL) == FERALIN_OK);
  feralin_client_free(client); /* kalan olayları gönderir */
  CHECK(collector.calls == 1);
}

static void test_revenue_profile_and_error(void) {
  fake_collector collector;
  feralin_client* client;
  feralin_revenue revenue;
  feralin_props* extra = feralin_props_new();
  feralin_props* traits = feralin_props_new();
  feralin_track_result event;
  feralin_flush_result result;
  memset(&collector, 0, sizeof(collector));
  collector.next_status = 202;
  client = make_client(&collector, FERALIN_CONSENT_ANALYTICS);

  feralin_revenue_init(&revenue);
  CHECK(revenue.quantity == 1);
  revenue.transaction_id = "txn_c_1";
  revenue.amount_minor = 4999;
  revenue.currency = "TRY";
  revenue.product_id = "pro";
  revenue.receipt_provider = "apple";
  revenue.receipt_token = "rcpt";
  CHECK(feralin_props_set_bool(extra, "verified", 1) == FERALIN_OK);
  CHECK(feralin_props_set_string(extra, "coupon", "yaz") == FERALIN_OK);
  revenue.properties = extra;
  CHECK(feralin_track_revenue(client, &revenue, NULL, &event) == FERALIN_OK);
  CHECK(event.produced == 1);
  CHECK(feralin_flush(client, &result) == FERALIN_OK);
  CHECK(strstr(collector.last_body, "\"event_name\":\"feralin_purchase\"") != NULL);
  CHECK(strstr(collector.last_body, "\"amount_minor\":4999") != NULL);
  CHECK(strstr(collector.last_body, "\"quantity\":1") != NULL);
  CHECK(strstr(collector.last_body, "\"purchase_type\":\"purchase\"") != NULL);
  CHECK(strstr(collector.last_body, "\"receipt\":{\"provider\":\"apple\",\"token\":\"rcpt\"}") != NULL);
  CHECK(strstr(collector.last_body, "\"coupon\":\"yaz\"") != NULL);
  CHECK(strstr(collector.last_body, "verified") == NULL);

  revenue.currency = "try";
  CHECK(feralin_track_revenue(client, &revenue, NULL, &event) == FERALIN_ERR_INVALID_EVENT);
  CHECK(event.produced == 0);
  revenue.currency = "TRY";
  revenue.purchase_type = "subscription_cancel";
  CHECK(feralin_track_revenue(client, &revenue, NULL, &event) == FERALIN_ERR_INVALID_EVENT);
  revenue.struct_size = 0;
  CHECK(feralin_track_revenue(client, &revenue, NULL, &event) == FERALIN_ERR_CONFIGURATION);
  CHECK(feralin_track_revenue(client, NULL, NULL, &event) == FERALIN_ERR_INTERNAL);

  CHECK(feralin_props_set_string(traits, "plan", "enterprise") == FERALIN_OK);
  CHECK(feralin_props_set_string(traits, "email", "a@b.co") == FERALIN_OK);
  CHECK(feralin_group(client, "acme", traits, NULL, &event) == FERALIN_OK);
  CHECK(event.produced == 1);
  CHECK(feralin_group(client, "a@b", traits, NULL, &event) == FERALIN_OK);
  CHECK(event.produced == 0);
  CHECK(feralin_set_user_properties(client, traits, NULL, &event) == FERALIN_OK);
  CHECK(event.produced == 1);
  CHECK(feralin_set_user_properties(client, NULL, NULL, &event) == FERALIN_OK);
  CHECK(event.produced == 0);
  CHECK(feralin_flush(client, &result) == FERALIN_OK);
  CHECK(strstr(collector.last_body, "\"event_name\":\"fr_group\"") != NULL);
  CHECK(strstr(collector.last_body, "\"group_id\":\"acme\"") != NULL);
  CHECK(strstr(collector.last_body, "\"event_name\":\"fr_user_properties\"") != NULL);
  CHECK(strstr(collector.last_body, "a@b.co") == NULL);

  CHECK(feralin_capture_error(client, "IOError", "disk full at /home/x for a@b.co", FERALIN_ERROR_ORIGIN_HANDLED, 0, NULL, &event) == FERALIN_OK);
  CHECK(event.produced == 1);
  CHECK(feralin_capture_error(client, NULL, NULL, FERALIN_ERROR_ORIGIN_UNCAUGHT, 1, NULL, &event) == FERALIN_OK);
  CHECK(event.produced == 1);
  CHECK(feralin_capture_error(client, "IOError", "x", 7, 0, NULL, &event) == FERALIN_ERR_INVALID_EVENT);
  CHECK(feralin_flush(client, &result) == FERALIN_OK);
  CHECK(strstr(collector.last_body, "\"event_name\":\"fr_error\"") != NULL);
  CHECK(strstr(collector.last_body, "\"message\":\"disk full at /home/x for [email]\"") != NULL);
  CHECK(strstr(collector.last_body, "\"handled\":true,\"fatal\":false,\"origin\":\"handled\"") != NULL);
  CHECK(strstr(collector.last_body, "\"error_type\":\"Error\"") != NULL);
  CHECK(strstr(collector.last_body, "\"handled\":false,\"fatal\":true,\"origin\":\"uncaught_exception\"") != NULL);

  feralin_props_free(extra);
  feralin_props_free(traits);
  feralin_client_free(client);
}

static void test_error_options(void) {
  fake_collector collector;
  feralin_options options;
  feralin_client* client = NULL;
  feralin_track_result event;
  feralin_flush_result result;
  memset(&collector, 0, sizeof(collector));
  collector.next_status = 202;
  feralin_options_init(&options);
  CHECK(options.error_sample_rate == 1.0);
  options.project_key = "pk_test_c_api_0001";
  options.collect_url = "https://collect.example.test/";
  options.consent = FERALIN_CONSENT_ANALYTICS;
  options.flush_interval_ms = 0;
  options.transport = fake_transport;
  options.transport_user_data = &collector;
  options.app_version = "4.0.1";
  CHECK(feralin_client_new(&options, &client) == FERALIN_OK);
  CHECK(feralin_capture_error(client, "E", "m", FERALIN_ERROR_ORIGIN_MANUAL, 0, NULL, &event) == FERALIN_OK);
  CHECK(feralin_flush(client, &result) == FERALIN_OK);
  CHECK(strstr(collector.last_body, "\"app_version\":\"4.0.1\"") != NULL);
  feralin_client_free(client);

  options.error_sample_rate = 0.0;
  client = NULL;
  CHECK(feralin_client_new(&options, &client) == FERALIN_OK);
  CHECK(feralin_capture_error(client, "E", "m", FERALIN_ERROR_ORIGIN_MANUAL, 0, NULL, &event) == FERALIN_OK);
  CHECK(event.produced == 0);
  feralin_client_free(client);
}

int main(void) {
  test_config();
  test_null_safety();
  test_track_and_flush();
  test_consent();
  test_failures();
  test_logger_and_queue_limit();
  test_revenue_profile_and_error();
  test_error_options();
  printf("%d denetim, %d kaldı\n", g_checks, g_failures);
  return g_failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
