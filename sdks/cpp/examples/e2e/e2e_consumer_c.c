/* Kararlı C API'nin gerçek services/collect karşısındaki tüketicisi: fr_click izni, izin kapısı ve yanlış anahtar. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <feralin/feralin.h>

static const char* required_env(const char* name) {
  const char* value = getenv(name);
  if (value == NULL || *value == '\0') {
    fprintf(stderr, "KALDI: %s ortam değişkeni yok\n", name);
    exit(1);
  }
  return value;
}

static void must(int condition, const char* message) {
  if (!condition) {
    fprintf(stderr, "KALDI: %s (%s)\n", message, feralin_last_error());
    exit(1);
  }
}

static void expect_line(const char* checks, const char* kind, const char* id) {
  FILE* file = fopen(checks, "ab");
  must(file != NULL, "denetim dosyası açılamadı");
  fprintf(file, "%s %s\n", kind, id);
  fclose(file);
}

static feralin_client* make(const char* key, const char* url, unsigned int consent) {
  feralin_options options;
  feralin_client* client = NULL;
  feralin_options_init(&options);
  options.project_key = key;
  options.collect_url = url;
  options.consent = consent;
  options.flush_interval_ms = 0;
  must(feralin_client_new(&options, &client) == FERALIN_OK, "istemci açılamadı");
  return client;
}

int main(void) {
  const char* url = required_env("FERALIN_E2E_COLLECT_URL");
  const char* key = required_env("FERALIN_E2E_PROJECT_KEY");
  const char* checks = required_env("FERALIN_E2E_CHECKS");
  feralin_client* client;
  feralin_props* properties = feralin_props_new();
  feralin_track_result event;
  feralin_flush_result result;
  must(properties != NULL, "özellik nesnesi açılamadı");
  must(feralin_props_set_string(properties, "order_id", "ord_c_1") == FERALIN_OK, "özellik yazılamadı");
  must(feralin_props_set_string(properties, "fr_click", "clk_c_1") == FERALIN_OK, "özellik yazılamadı");

  /* 202 + fr_click reklam izniyle */
  client = make(key, url, FERALIN_CONSENT_ANALYTICS | FERALIN_CONSENT_ADVERTISING);
  must(feralin_track(client, "order_completed", properties, NULL, &event) == FERALIN_OK && event.produced == 1, "olay üretilmeliydi");
  must(feralin_flush(client, &result) == FERALIN_OK && result.http_status == 202 && result.accepted == 1, "202 bekleniyordu");
  expect_line(checks, "frclick", result.batch_id);
  expect_line(checks, "once", event.event_id);
  feralin_client_free(client);
  printf("  OK c-202-frclick: batch_id=%s\n", result.batch_id);

  /* Reklam izni yok: fr_click çıkarılır */
  client = make(key, url, FERALIN_CONSENT_ANALYTICS);
  must(feralin_track(client, "order_completed", properties, NULL, &event) == FERALIN_OK, "olay üretilmeliydi");
  must(feralin_flush(client, &result) == FERALIN_OK && result.http_status == 202, "202 bekleniyordu");
  expect_line(checks, "nofrclick", result.batch_id);
  feralin_client_free(client);
  printf("  OK c-frclick-cikarildi\n");

  /* İzinsiz: olay üretilmez */
  client = make(key, url, 0);
  must(feralin_track(client, "order_completed", properties, NULL, &event) == FERALIN_OK && event.produced == 0, "izinsiz olay üretilmemeliydi");
  must(feralin_flush(client, &result) == FERALIN_OK && result.sent == 0, "istek gitmemeliydi");
  feralin_client_free(client);
  printf("  OK c-izinsiz-uretmez\n");

  /* Yanlış anahtar: 401, olay atılır, süreç düşmez */
  client = make("pk_test_wrong_key_000", url, FERALIN_CONSENT_ANALYTICS);
  must(feralin_track(client, "order_completed", properties, NULL, &event) == FERALIN_OK, "olay üretilmeliydi");
  must(feralin_flush(client, &result) == FERALIN_ERR_REJECTED && result.http_status == 401 && feralin_queue_length(client) == 0, "401 bekleniyordu");
  expect_line(checks, "absent", event.event_id);
  feralin_client_free(client);
  printf("  OK c-yanlis-anahtar-401\n");

  feralin_props_free(properties);
  printf("c tüketici: tüm senaryolar geçti\n");
  return 0;
}
