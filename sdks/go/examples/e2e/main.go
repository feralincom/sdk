// Gerçek services/collect tüketicisi: scripts/sdk-e2e/run.mjs go tarafından çalıştırılır. Denetim satırları
// sdks/android/scripts/outbox_check.go ile PostgreSQL üzerinde doğrulanır.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	feralin "github.com/feralincom/sdk/sdks/go"
)

var ctx = context.Background()

func must(condition bool, message string) {
	if !condition {
		fmt.Fprintln(os.Stderr, "KALDI:", message)
		os.Exit(1)
	}
}

func report(name string, detail any) {
	encoded, _ := json.Marshal(detail)
	fmt.Printf("  OK %s: %s\n", name, encoded)
}

// lossyTransport ilk isteği sunucuya ulaştırır, yanıtı uygulamaya vermez: yolda kaybolan yanıtı gerçek toplayıcıyla canlandırır.
type lossyTransport struct {
	first bool
	keys  []string
}

func (l *lossyTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	l.keys = append(l.keys, req.Header.Get("Idempotency-Key"))
	resp, err := http.DefaultTransport.RoundTrip(req)
	if err != nil {
		return nil, err
	}
	if !l.first {
		l.first = true
		resp.Body.Close()
		return nil, errors.New("yanıt yolda kayboldu")
	}
	return resp, nil
}

func main() {
	collectURL := os.Getenv("FERALIN_E2E_COLLECT_URL")
	projectKey := os.Getenv("FERALIN_E2E_PROJECT_KEY")
	checksPath := os.Getenv("FERALIN_E2E_CHECKS")
	must(collectURL != "" && projectKey != "" && checksPath != "", "ortam değişkenleri zorunlu")
	checks, err := os.OpenFile(checksPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	must(err == nil, "denetim dosyası açılamadı")
	defer checks.Close()
	expect := func(line string) { fmt.Fprintln(checks, line) }
	make := func(key string, consent feralin.Consent, extra ...feralin.Option) *feralin.Client {
		client, err := feralin.NewClient(key, collectURL, append([]feralin.Option{feralin.WithFlushInterval(0), feralin.WithConsent(consent)}, extra...)...)
		must(err == nil, "istemci oluşturulamadı")
		return client
	}

	// 202 + outbox satırı + fr_click reklam izniyle
	client := make(projectKey, feralin.Consent{Analytics: true, Advertising: true})
	event, err := client.Track(ctx, feralin.Event{Name: "order_completed", UserID: "user_go_1", Properties: map[string]any{"order_id": "ord_go_1", "fr_click": "clk_go_1"}})
	must(err == nil && event != nil, "olay üretilmeliydi")
	result, err := client.Flush(ctx)
	must(err == nil && result.Status == 202 && result.Accepted == 1, "202 bekleniyordu")
	expect("frclick " + result.BatchID)
	expect("once " + event.EventID)
	report("202-outbox-frclick", result)

	// Reklam izni yok: fr_click çıkarılır
	client = make(projectKey, feralin.Consent{Analytics: true})
	event, err = client.Track(ctx, feralin.Event{Name: "order_completed", Properties: map[string]any{"order_id": "ord_go_2", "fr_click": "clk_go_2"}})
	must(err == nil && event != nil, "olay üretilmeliydi")
	_, hasClick := event.Properties["fr_click"]
	must(!hasClick, "fr_click çıkarılmalıydı")
	result, err = client.Flush(ctx)
	must(err == nil && result.Status == 202, "202 bekleniyordu")
	expect("nofrclick " + result.BatchID)
	report("frclick-izinsiz-cikarildi", result.Status)

	// İzinsiz: SDK olay üretmez
	client = make(projectKey, feralin.Consent{})
	event, err = client.Track(ctx, feralin.Event{Name: "order_completed"})
	must(err == nil && event == nil, "izinsiz olay üretilmemeliydi")
	report("izinsiz-sdk-uretmez", client.Len())

	// İzinsiz ham istek: toplayıcı olay düzeyinde reddeder
	id := fmt.Sprintf("01JCGO%020d", time.Now().UnixNano())[:26]
	body, _ := json.Marshal(map[string]any{"events": []map[string]any{{
		"event_id": id, "event_name": "denied_event", "occurred_at": time.Now().UTC().Format(time.RFC3339), "platform": "go", "schema_version": 1, "consent": map[string]any{"analytics": false},
	}}})
	request, _ := http.NewRequest(http.MethodPost, collectURL+"/v1/batch", strings.NewReader(string(body)))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("X-Feralin-Project-Key", projectKey)
	request.Header.Set("Idempotency-Key", feralin.IdempotencyKeyFor([]string{id}))
	response, err := http.DefaultClient.Do(request)
	must(err == nil, "ham istek başarısız")
	var denied struct {
		Accepted int            `json:"accepted"`
		Reasons  map[string]int `json:"rejected_reasons"`
	}
	must(json.NewDecoder(response.Body).Decode(&denied) == nil, "yanıt çözülemedi")
	response.Body.Close()
	must(response.StatusCode == 202 && denied.Accepted == 0 && denied.Reasons["consent_denied"] == 1, "toplayıcı izinsiz olayı reddetmeliydi")
	expect("absent " + id)
	report("izinsiz-toplayici-red", denied.Reasons)

	// Yanlış anahtar: 401, olay atılır, uygulama düşmez
	client = make("pk_test_wrong_key_000", feralin.Consent{Analytics: true})
	event, err = client.Track(ctx, feralin.Event{Name: "order_completed", Properties: map[string]any{"order_id": "ord_go_wrong"}})
	must(err == nil && event != nil, "olay üretilmeliydi")
	result, err = client.Flush(ctx)
	must(errors.Is(err, feralin.ErrRejected) && result.Status == 401 && result.Rejected == 1 && client.Len() == 0, "401 bekleniyordu")
	expect("absent " + event.EventID)
	report("yanlis-anahtar-401", result.Status)

	// Idempotency: sunucu yazdı ama yanıt kayboldu; aynı anahtarla tekrar tek outbox satırı üretir
	lossy := &lossyTransport{}
	client = make(projectKey, feralin.Consent{Analytics: true}, feralin.WithHTTPClient(&http.Client{Transport: lossy, Timeout: 10 * time.Second}))
	event, err = client.Track(ctx, feralin.Event{Name: "order_completed", Properties: map[string]any{"order_id": "ord_go_retry"}})
	must(err == nil && event != nil, "olay üretilmeliydi")
	_, err = client.Flush(ctx)
	must(errors.Is(err, feralin.ErrTemporary) && client.Len() == 1, "yanıt kaybı kuyrukta tutulmalıydı")
	next, err := client.Track(ctx, feralin.Event{Name: "order_shipped", Properties: map[string]any{"order_id": "ord_go_retry"}})
	must(err == nil && next != nil, "olay üretilmeliydi")
	result, err = client.Flush(ctx)
	must(err == nil && result.Status == 202 && client.Len() == 0, "tekrar 202 vermeliydi")
	must(len(lossy.keys) == 3 && lossy.keys[0] == lossy.keys[1], "aynı anahtar bekleniyordu")
	expect("once " + event.EventID)
	expect("once " + next.EventID)
	report("idempotency-tekrar", lossy.keys[0])

	// Aynı olay farklı anahtarla yeniden gönderilir (ör. uygulama kendi yeniden denemesini yaptı): toplayıcı anahtar başına
	// tekilleştirdiğinden iki outbox satırı oluşur, aynı anahtarın üçüncü gönderimi satır eklemez. ClickHouse'ta olay bir kez
	// sayılmalıdır (run.mjs SDK_E2E_CLICKHOUSE_URL verildiğinde worker'la doğrular).
	dupID := fmt.Sprintf("01JCGD%020d", time.Now().UnixNano())[:26]
	dupBody, _ := json.Marshal(map[string]any{"events": []map[string]any{{
		"event_id": dupID, "event_name": "order_completed", "occurred_at": time.Now().UTC().Format(time.RFC3339), "platform": "go", "schema_version": 1,
		"consent": map[string]any{"analytics": true}, "properties": map[string]any{"order_id": "ord_go_dup"},
	}}})
	send := func(key string) int {
		request, _ := http.NewRequest(http.MethodPost, collectURL+"/v1/batch", strings.NewReader(string(dupBody)))
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("X-Feralin-Project-Key", projectKey)
		request.Header.Set("Idempotency-Key", key)
		response, err := http.DefaultClient.Do(request)
		must(err == nil, "ham istek başarısız")
		var accepted struct {
			Accepted int `json:"accepted"`
		}
		must(json.NewDecoder(response.Body).Decode(&accepted) == nil, "yanıt çözülemedi")
		response.Body.Close()
		must(response.StatusCode == 202, fmt.Sprintf("yeniden gönderim 202 vermeliydi: %d", response.StatusCode))
		return accepted.Accepted
	}
	firstKey := feralin.IdempotencyKeyFor([]string{dupID})
	must(send(firstKey) == 1 && send(firstKey+"-yeniden") == 1, "iki farklı anahtar kabul edilmeliydi")
	send(firstKey)
	expect("twice " + dupID)
	report("ayni-olay-farkli-anahtar", dupID)

	// Kimlik yöntemleri (UTP §8.2): global özellik her olaya, kullanıcı özelliği ve grup ayrı sistem olayı. Toplayıcı izin listesi plan,tier.
	profilePath := os.Getenv("FERALIN_E2E_PROFILE_CHECKS")
	must(profilePath != "", "FERALIN_E2E_PROFILE_CHECKS zorunlu")
	profileChecks, err := os.OpenFile(profilePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	must(err == nil, "kimlik denetim dosyası açılamadı")
	defer profileChecks.Close()
	expectProfile := func(line string) { fmt.Fprintln(profileChecks, line) }
	who := feralin.Identity{AnonymousID: "anon_go_profile"}
	client = make(projectKey, feralin.Consent{Analytics: true})
	client.SetGlobalProperties(map[string]any{"app_release": "e2e"})
	tracked, err := client.Track(ctx, feralin.Event{Name: "profile_e2e_page", AnonymousID: who.AnonymousID})
	must(err == nil && tracked != nil, "olay üretilmeliydi")
	props, err := client.SetUserProperties(ctx, map[string]any{"plan": "pro", "tier": 2, "secret_note": "x", "email": "kisi@example.com"}, who)
	must(err == nil && props != nil, "kullanıcı özelliği olayı üretilmeliydi")
	_, hasEmail := props.Properties["email"]
	must(!hasEmail, "kişisel veri anahtarı istemcide düşmeliydi")
	grouped, err := client.Group(ctx, "acme-team", map[string]any{"plan": "team"}, who)
	must(err == nil && grouped != nil, "grup olayı üretilmeliydi")
	rejected, err := client.Group(ctx, "kisi@example.com", nil, who)
	must(err == nil && rejected == nil, "e-posta biçimli grup kimliği reddedilmeliydi")
	result, err = client.Flush(ctx)
	must(err == nil && result.Status == 202 && result.Accepted == 3, "kimlik olayları 202 ile kabul edilmeliydi")
	expect("once " + tracked.EventID)
	expectProfile("prop " + tracked.EventID + ` app_release="e2e"`)
	expectProfile("name fr_user_properties:" + props.EventID)
	expectProfile("prop " + props.EventID + ` plan="pro"`)
	expectProfile("prop " + props.EventID + " tier=2")
	expectProfile("noprop " + props.EventID + " secret_note")
	expectProfile("noprop " + props.EventID + " app_release")
	expectProfile("name fr_group:" + grouped.EventID)
	expectProfile("prop " + grouped.EventID + ` group_id="acme-team"`)
	expectProfile("prop " + grouped.EventID + ` plan="team"`)
	report("kimlik-yontemleri", result)

	fmt.Println("go tüketici: tüm senaryolar geçti")
}
