package feralin

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"
)

const testKey = "pk_live_0123456789abcdef0123456789abcdef"

// recordedRequest testteki sahte toplayıcının aldığı tek bir isteği tutar.
type recordedRequest struct {
	Headers http.Header
	Body    map[string]any
}

// fakeCollector httptest üzerinde çalışan, yanıtları önceden yazılmış bir /v1/batch sunucusudur.
type fakeCollector struct {
	t        *testing.T
	mu       sync.Mutex
	requests []recordedRequest
	script   []scripted
	received chan struct{}
	srv      *httptest.Server
}

type scripted struct {
	status  int
	body    string
	headers map[string]string
}

func newFakeCollector(t *testing.T, script ...scripted) *fakeCollector {
	t.Helper()
	fc := &fakeCollector{t: t, script: script, received: make(chan struct{}, 64)}
	fc.srv = httptest.NewServer(http.HandlerFunc(fc.handle))
	t.Cleanup(fc.srv.Close)
	return fc
}

func (fc *fakeCollector) handle(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/batch" || r.Method != http.MethodPost {
		http.Error(w, "yanlış yol", http.StatusNotFound)
		return
	}
	raw, _ := io.ReadAll(r.Body)
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		fc.t.Errorf("gövde JSON değil: %v", err)
	}
	fc.mu.Lock()
	fc.requests = append(fc.requests, recordedRequest{Headers: r.Header.Clone(), Body: body})
	resp := scripted{status: http.StatusAccepted, body: `{"batch_id":"01TESTBATCH0000000000000000","accepted":` + itoa(countEvents(body)) + `,"rejected":0}`}
	if len(fc.script) > 0 {
		resp = fc.script[0]
		fc.script = fc.script[1:]
	}
	fc.mu.Unlock()

	for k, v := range resp.headers {
		w.Header().Set(k, v)
	}
	if resp.status >= 400 {
		w.Header().Set("Content-Type", "application/problem+json")
	} else {
		w.Header().Set("Content-Type", "application/json")
	}
	w.WriteHeader(resp.status)
	_, _ = w.Write([]byte(resp.body))
	fc.received <- struct{}{}
}

func (fc *fakeCollector) count() int {
	fc.mu.Lock()
	defer fc.mu.Unlock()
	return len(fc.requests)
}

func (fc *fakeCollector) request(i int) recordedRequest {
	fc.mu.Lock()
	defer fc.mu.Unlock()
	return fc.requests[i]
}

func countEvents(body map[string]any) int {
	ev, _ := body["events"].([]any)
	return len(ev)
}

func itoa(n int) string {
	b, _ := json.Marshal(n)
	return string(b)
}

func newTestClient(t *testing.T, fc *fakeCollector, opts ...Option) *Client {
	t.Helper()
	base := []Option{
		WithConsent(Consent{Analytics: true}),
		WithFlushInterval(0), // arka plan kapalı; testler Flush/Close ile kontrol eder
		WithHTTPClient(fc.srv.Client()),
	}
	c, err := NewClient(testKey, fc.srv.URL, append(base, opts...)...)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	t.Cleanup(func() { _ = c.Close() })
	return c
}

func TestNewClientKeyAndURLValidation(t *testing.T) {
	cases := []struct {
		name, key, url string
		want           error
	}{
		{"gizli anahtar", "sk_live_abcdefgh", "http://127.0.0.1:1", ErrSecretKey},
		{"pk_ olmayan", "dev_key_change_me_0001", "http://127.0.0.1:1", ErrInvalidProjectKey},
		{"boş anahtar", "", "http://127.0.0.1:1", ErrInvalidProjectKey},
		{"şemasız url", testKey, "collect.example.test", ErrInvalidCollectURL},
		{"ftp url", testKey, "ftp://collect.example.test", ErrInvalidCollectURL},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, err := NewClient(tc.key, tc.url, WithFlushInterval(0))
			if !errors.Is(err, tc.want) {
				t.Fatalf("hata %v bekleniyordu, %v geldi", tc.want, err)
			}
		})
	}
	c, err := NewClient(testKey, "https://collect.example.test/", WithFlushInterval(0))
	if err != nil {
		t.Fatalf("geçerli yapılandırma reddedildi: %v", err)
	}
	if got := c.Status().Endpoint; got != "https://collect.example.test/v1/batch" {
		t.Fatalf("endpoint %q", got)
	}
	_ = c.Close()
}

func TestTrackFlushAccepted(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc)
	if err := c.Identify("user_42"); err != nil {
		t.Fatal(err)
	}

	ev, err := c.Track(context.Background(), Event{
		Name:        "order_completed",
		AnonymousID: "anon_1",
		SessionID:   "ses_1",
		Properties:  map[string]any{"order_id": "ord_1", "amount": 12.5, "items": 2},
		Context:     &Context{Locale: "tr-TR", Timezone: "Europe/Istanbul", App: &AppInfo{Version: "1.2.3"}},
	})
	if err != nil || ev == nil {
		t.Fatalf("Track: ev=%v err=%v", ev, err)
	}
	if !isULID(ev.EventID) {
		t.Fatalf("event_id ULID değil: %q", ev.EventID)
	}
	if ev.UserID != "user_42" || ev.Platform != "go" || ev.SchemaVersion != 1 || ev.SDK.Name != "feralin-go" || ev.SDK.Version != SDKVersion {
		t.Fatalf("sabit alanlar hatalı: %+v", ev)
	}
	if c.Len() != 1 {
		t.Fatalf("kuyruk 1 olmalı, %d", c.Len())
	}

	res, err := c.Flush(context.Background())
	if err != nil {
		t.Fatalf("Flush: %v", err)
	}
	if res.Status != 202 || res.Sent != 1 || res.Accepted != 1 || res.Rejected != 0 || res.BatchID != "01TESTBATCH0000000000000000" {
		t.Fatalf("FlushResult beklenmedik: %+v", res)
	}
	if c.Len() != 0 {
		t.Fatalf("ack sonrası kuyruk boş olmalı, %d", c.Len())
	}
	if fc.count() != 1 {
		t.Fatalf("1 istek bekleniyordu, %d", fc.count())
	}

	req := fc.request(0)
	if got := req.Headers.Get("X-Feralin-Project-Key"); got != testKey {
		t.Fatalf("X-Feralin-Project-Key %q", got)
	}
	if got := req.Headers.Get("Idempotency-Key"); got != IdempotencyKeyFor([]string{ev.EventID}) {
		t.Fatalf("Idempotency-Key %q", got)
	}
	if got := req.Headers.Get("Content-Type"); got != "application/json" {
		t.Fatalf("Content-Type %q", got)
	}
	if _, ok := req.Body["sent_at"].(string); !ok {
		t.Fatalf("sent_at yok: %v", req.Body)
	}
	events, _ := req.Body["events"].([]any)
	if len(events) != 1 {
		t.Fatalf("1 olay bekleniyordu: %v", req.Body)
	}
	wire := events[0].(map[string]any)
	assertWireEvent(t, wire)
	if wire["user_id"] != "user_42" || wire["anonymous_id"] != "anon_1" || wire["session_id"] != "ses_1" {
		t.Fatalf("kimlikler hatalı: %v", wire)
	}
	props := wire["properties"].(map[string]any)
	if props["order_id"] != "ord_1" || props["items"] != float64(2) {
		t.Fatalf("properties hatalı: %v", props)
	}
	ctxMap := wire["context"].(map[string]any)
	if ctxMap["locale"] != "tr-TR" || ctxMap["app"].(map[string]any)["version"] != "1.2.3" {
		t.Fatalf("context hatalı: %v", ctxMap)
	}
	if _, has := ctxMap["page_url"]; has {
		t.Fatalf("boş context alanı gönderilmemeli: %v", ctxMap)
	}
}

// assertWireEvent tel üzerindeki olayın UTP v1 şema kurallarına uyduğunu elle denetler (jsonschema bağımlılığı yok).
func assertWireEvent(t *testing.T, wire map[string]any) {
	t.Helper()
	for _, k := range []string{"event_id", "event_name", "occurred_at", "platform", "schema_version", "consent"} {
		if _, ok := wire[k]; !ok {
			t.Fatalf("zorunlu alan eksik: %s (%v)", k, wire)
		}
	}
	for _, forbidden := range []string{"tenant_id", "project_id", "verified", "source_ip", "ip"} {
		if _, has := wire[forbidden]; has {
			t.Fatalf("istemciden gönderilmemesi gereken alan var: %s", forbidden)
		}
	}
	if wire["platform"] != "go" || wire["schema_version"] != float64(1) {
		t.Fatalf("platform/schema_version hatalı: %v", wire)
	}
	occurred := wire["occurred_at"].(string)
	if !regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$`).MatchString(occurred) {
		t.Fatalf("occurred_at UTC RFC3339 ms biçiminde değil: %q", occurred)
	}
	if _, err := time.Parse(time.RFC3339Nano, occurred); err != nil {
		t.Fatalf("occurred_at ayrıştırılamadı: %v", err)
	}
	consent := wire["consent"].(map[string]any)
	if consent["analytics"] != true {
		t.Fatalf("consent.analytics true olmalı: %v", consent)
	}
	sdk := wire["sdk"].(map[string]any)
	if sdk["name"] != "feralin-go" || sdk["version"] != SDKVersion {
		t.Fatalf("sdk alanı hatalı: %v", sdk)
	}

	// Kanonik şema dosyası monorepo içinde varsa alan adlarını onunla da karşılaştır.
	schemaPath := filepath.Join("..", "..", "packages", "schemas", "utp", "v1", "event.schema.json")
	raw, err := os.ReadFile(schemaPath)
	if err != nil {
		t.Logf("kanonik şema bulunamadı (%v); alan listesi karşılaştırması atlandı", err)
		return
	}
	var schema struct {
		Required   []string                   `json:"required"`
		Properties map[string]json.RawMessage `json:"properties"`
	}
	if err := json.Unmarshal(raw, &schema); err != nil {
		t.Fatalf("şema okunamadı: %v", err)
	}
	for k := range wire {
		if _, ok := schema.Properties[k]; !ok {
			t.Fatalf("şemada olmayan alan gönderildi: %s", k)
		}
	}
	for _, k := range schema.Required {
		if _, ok := wire[k]; !ok {
			t.Fatalf("şemanın zorunlu alanı eksik: %s", k)
		}
	}
}

func TestTemporaryFailureKeepsQueueAndIdempotencyKey(t *testing.T) {
	fc := newFakeCollector(t,
		scripted{status: 503, body: `{"type":"urn:feralin:collect:problem:outbox","title":"Outbox yazılamadı"}`, headers: map[string]string{"Retry-After": "5"}},
		scripted{status: 429, body: `{"title":"Çok fazla istek"}`, headers: map[string]string{"Retry-After": "1"}},
	)
	c := newTestClient(t, fc)
	ev, err := c.Track(context.Background(), Event{Name: "signup"})
	if err != nil {
		t.Fatal(err)
	}

	res, err := c.Flush(context.Background())
	if !errors.Is(err, ErrTemporary) {
		t.Fatalf("503 için ErrTemporary bekleniyordu: %v", err)
	}
	if res.Status != 503 || res.Retained != 1 || c.Len() != 1 {
		t.Fatalf("503 sonrası kuyrukta kalmalı: %+v len=%d", res, c.Len())
	}
	if b := c.Status().Backoff; b != 5*time.Second {
		t.Fatalf("Retry-After: 5 ile backoff 5s olmalı, %v", b)
	}

	res, err = c.Flush(context.Background())
	if !errors.Is(err, ErrTemporary) || res.Status != 429 || c.Len() != 1 {
		t.Fatalf("429 sonrası kuyrukta kalmalı: err=%v res=%+v len=%d", err, res, c.Len())
	}
	if b := c.Status().Backoff; b != 10*time.Second {
		t.Fatalf("ikinci hata sonrası backoff 10s olmalı (üstel), %v", b)
	}

	res, err = c.Flush(context.Background())
	if err != nil || res.Status != 202 || c.Len() != 0 {
		t.Fatalf("202 sonrası ack bekleniyordu: err=%v res=%+v len=%d", err, res, c.Len())
	}
	if b := c.Status().Backoff; b != 0 {
		t.Fatalf("başarı backoff'u sıfırlamalı, %v", b)
	}

	if fc.count() != 3 {
		t.Fatalf("3 istek bekleniyordu, %d", fc.count())
	}
	want := IdempotencyKeyFor([]string{ev.EventID})
	for i := 0; i < 3; i++ {
		if got := fc.request(i).Headers.Get("Idempotency-Key"); got != want {
			t.Fatalf("istek %d Idempotency-Key %q, beklenen %q (yeniden denemede sabit kalmalı)", i, got, want)
		}
	}
}

func TestIdempotencyKeyMatchesOtherSDKs(t *testing.T) {
	got := IdempotencyKeyFor([]string{"01JC0000000000000000000002", "01JC0000000000000000000001"})
	if got != "8f95d6b736d56c98-2" {
		t.Fatalf("Web SDK ile aynı anahtar bekleniyordu: %q", got)
	}
}

func TestFrClickRequiresAdvertisingConsent(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc)
	props := map[string]any{"fr_click": "clk", "order_id": "o1"}
	ev, err := c.Track(context.Background(), Event{Name: "order_completed", Properties: props})
	if err != nil {
		t.Fatal(err)
	}
	if _, has := ev.Properties["fr_click"]; has || ev.Properties["order_id"] != "o1" {
		t.Fatalf("reklam izni yokken fr_click çıkarılmalı: %+v", ev.Properties)
	}
	if _, has := props["fr_click"]; !has {
		t.Fatal("çağıranın haritası değişmemeli")
	}
	c.SetConsent(Consent{Analytics: true, Advertising: true})
	ev, err = c.Track(context.Background(), Event{Name: "order_completed", Properties: props})
	if err != nil {
		t.Fatal(err)
	}
	if ev.Properties["fr_click"] != "clk" {
		t.Fatalf("reklam izniyle fr_click gitmeli: %+v", ev.Properties)
	}
}

func TestPinnedBatchKeepsContentAcrossRetries(t *testing.T) {
	fc := newFakeCollector(t, scripted{status: 503, body: `{}`})
	c := newTestClient(t, fc)
	first, err := c.Track(context.Background(), Event{Name: "first_event"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Flush(context.Background()); !errors.Is(err, ErrTemporary) {
		t.Fatalf("503 için ErrTemporary bekleniyordu: %v", err)
	}
	second, err := c.Track(context.Background(), Event{Name: "second_event"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if fc.count() != 3 {
		t.Fatalf("3 istek bekleniyordu, %d", fc.count())
	}
	if a, b := fc.request(0).Headers.Get("Idempotency-Key"), fc.request(1).Headers.Get("Idempotency-Key"); a != b || a != IdempotencyKeyFor([]string{first.EventID}) {
		t.Fatalf("yeniden deneme aynı anahtarla gitmeli: %q %q", a, b)
	}
	if got := fc.request(2).Headers.Get("Idempotency-Key"); got != IdempotencyKeyFor([]string{second.EventID}) {
		t.Fatalf("yeni olay ayrı batch'te gitmeli: %q", got)
	}
}

func TestNetworkErrorKeepsQueue(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc)
	fc.srv.Close() // sunucu kapalı → bağlantı hatası
	if _, err := c.Track(context.Background(), Event{Name: "ping"}); err != nil {
		t.Fatal(err)
	}
	res, err := c.Flush(context.Background())
	if !errors.Is(err, ErrTemporary) || res.Status != 0 || c.Len() != 1 {
		t.Fatalf("ağ hatasında ErrTemporary ve kuyrukta kalma bekleniyordu: err=%v res=%+v len=%d", err, res, c.Len())
	}
	if b := c.Status().Backoff; b != time.Second {
		t.Fatalf("ilk hata backoff 1s olmalı, %v", b)
	}
}

func TestPermanentRejectionDropsEvents(t *testing.T) {
	fc := newFakeCollector(t,
		scripted{status: 400, body: `{"type":"urn:feralin:collect:problem:schema","title":"Şema ihlali","detail":"events[0].event_name"}`},
	)
	c := newTestClient(t, fc)
	if _, err := c.Track(context.Background(), Event{Name: "bad_but_client_valid"}); err != nil {
		t.Fatal(err)
	}
	res, err := c.Flush(context.Background())
	if !errors.Is(err, ErrRejected) {
		t.Fatalf("400 için ErrRejected bekleniyordu: %v", err)
	}
	if !strings.Contains(err.Error(), "Şema ihlali") {
		t.Fatalf("hata problem başlığını içermeli: %v", err)
	}
	if res.Status != 400 || res.Rejected != 1 || c.Len() != 0 {
		t.Fatalf("400 sonrası olay atılmalı: %+v len=%d", res, c.Len())
	}
	if _, err := c.Flush(context.Background()); err != nil {
		t.Fatalf("boş kuyrukta Flush hatasız olmalı: %v", err)
	}
	if fc.count() != 1 {
		t.Fatalf("atılan olay yeniden gönderilmemeli, istek sayısı %d", fc.count())
	}
}

func TestConsentGate(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc, WithConsent(Consent{Analytics: false}))

	ev, err := c.Track(context.Background(), Event{Name: "page_view"})
	if ev != nil || err != nil {
		t.Fatalf("izin yokken (nil, nil) bekleniyordu: %v %v", ev, err)
	}
	if c.Len() != 0 {
		t.Fatalf("izin yokken kuyruk boş kalmalı")
	}

	c.SetConsent(Consent{Analytics: true, Advertising: false})
	ev, err = c.Track(context.Background(), Event{Name: "page_view"})
	if err != nil || ev == nil {
		t.Fatalf("izin sonrası olay üretilmeli: %v %v", ev, err)
	}
	if ev.Consent.Analytics != true || ev.Consent.Advertising != false {
		t.Fatalf("consent anlık görüntüsü hatalı: %+v", ev.Consent)
	}
	if c.Len() != 1 {
		t.Fatalf("kuyruk 1 olmalı")
	}

	// İzin geri çekilince bekleyen olaylar atılır, hiçbir şey gönderilmez.
	c.SetConsent(Consent{Analytics: false})
	if c.Len() != 0 {
		t.Fatalf("izin geri çekilince kuyruk temizlenmeli")
	}
	if _, err := c.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if fc.count() != 0 {
		t.Fatalf("izin yokken sunucuya istek gitmemeli, %d gitti", fc.count())
	}
}

func TestTrackValidation(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc)
	ctx := context.Background()

	cases := []struct {
		name string
		ev   Event
		want error
	}{
		{"boş ad", Event{Name: ""}, ErrInvalidEventName},
		{"camelCase ad", Event{Name: "orderCompleted"}, ErrInvalidEventName},
		{"rakamla başlayan ad", Event{Name: "1_event"}, ErrInvalidEventName},
		{"uzun ad", Event{Name: strings.Repeat("a", 101)}, ErrInvalidEventName},
		{"geçersiz property anahtarı", Event{Name: "ok", Properties: map[string]any{"1bad": 1}}, ErrInvalidPropertyKey},
		{"tireli property anahtarı", Event{Name: "ok", Properties: map[string]any{"bad-key": 1}}, ErrInvalidPropertyKey},
		{"uzun property anahtarı", Event{Name: "ok", Properties: map[string]any{"a" + strings.Repeat("b", 64): 1}}, ErrInvalidPropertyKey},
		{"uzun user_id", Event{Name: "ok", UserID: strings.Repeat("u", 129)}, ErrInvalidIdentifier},
		{"serileştirilemeyen değer", Event{Name: "ok", Properties: map[string]any{"fn": func() {}}}, ErrUnserializable},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ev, err := c.Track(ctx, tc.ev)
			if !errors.Is(err, tc.want) || ev != nil {
				t.Fatalf("%v bekleniyordu, ev=%v err=%v", tc.want, ev, err)
			}
		})
	}

	many := make(map[string]any, 101)
	for i := 0; i < 101; i++ {
		many["k"+itoa(i)] = i
	}
	if _, err := c.Track(ctx, Event{Name: "ok", Properties: many}); !errors.Is(err, ErrTooManyProperties) {
		t.Fatalf("101 anahtar için ErrTooManyProperties bekleniyordu: %v", err)
	}
	delete(many, "k100")
	if _, err := c.Track(ctx, Event{Name: "ok", Properties: many}); err != nil {
		t.Fatalf("100 anahtar kabul edilmeli: %v", err)
	}
	if _, err := c.Track(ctx, Event{Name: "fr_system_event_9", Properties: map[string]any{"Camel_Key9": "x"}}); err != nil {
		t.Fatalf("geçerli ad/anahtar reddedildi: %v", err)
	}
	if c.Len() != 2 {
		t.Fatalf("yalnız geçerli olaylar kuyruğa girmeli, len=%d", c.Len())
	}

	if err := c.Identify(strings.Repeat("u", 129)); !errors.Is(err, ErrInvalidIdentifier) {
		t.Fatalf("Identify uzun kimliği reddetmeli: %v", err)
	}

	cancelled, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := c.Track(cancelled, Event{Name: "ok"}); !errors.Is(err, context.Canceled) {
		t.Fatalf("iptal edilmiş context hatası bekleniyordu: %v", err)
	}
}

func TestQueueLimitDropsOldest(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc, WithQueueLimit(3), WithBatchSize(10))
	var ids []string
	for i := 0; i < 5; i++ {
		ev, err := c.Track(context.Background(), Event{Name: "e"})
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, ev.EventID)
	}
	if c.Len() != 3 || c.Status().Dropped != 2 {
		t.Fatalf("kuyruk 3, atılan 2 olmalı: len=%d dropped=%d", c.Len(), c.Status().Dropped)
	}
	if _, err := c.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	events := fc.request(0).Body["events"].([]any)
	got := []string{}
	for _, e := range events {
		got = append(got, e.(map[string]any)["event_id"].(string))
	}
	if strings.Join(got, ",") != strings.Join(ids[2:], ",") {
		t.Fatalf("en eski iki olay atılmalıydı: %v", got)
	}
}

func TestBatchSplitting(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc, WithBatchSize(2), WithQueueLimit(100))
	for i := 0; i < 5; i++ {
		if _, err := c.Track(context.Background(), Event{Name: "e"}); err != nil {
			t.Fatal(err)
		}
	}
	res, err := c.Flush(context.Background())
	if err != nil || res.Sent != 5 || res.Accepted != 5 || c.Len() != 0 {
		t.Fatalf("5 olay 3 batch'te gitmeli: err=%v res=%+v len=%d", err, res, c.Len())
	}
	if fc.count() != 3 {
		t.Fatalf("3 istek bekleniyordu, %d", fc.count())
	}
	first := fc.request(0)
	if n := countEvents(first.Body); n != 2 {
		t.Fatalf("ilk batch 2 olay olmalı, %d", n)
	}
	firstEvents := first.Body["events"].([]any)
	firstIDs := []string{firstEvents[0].(map[string]any)["event_id"].(string), firstEvents[1].(map[string]any)["event_id"].(string)}
	if got := first.Headers.Get("Idempotency-Key"); got != IdempotencyKeyFor(firstIDs) {
		t.Fatalf("Idempotency-Key tüm event_id özeti olmalı: %q", got)
	}
	if n := countEvents(fc.request(2).Body); n != 1 {
		t.Fatalf("son batch 1 olay olmalı, %d", n)
	}
}

func TestBackgroundFlush(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc, WithFlushInterval(20*time.Millisecond))
	if _, err := c.Track(context.Background(), Event{Name: "bg"}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-fc.received:
	case <-time.After(3 * time.Second):
		t.Fatal("arka plan gönderici 3 sn içinde istek yapmadı")
	}
	deadline := time.Now().Add(2 * time.Second)
	for c.Len() != 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if c.Len() != 0 {
		t.Fatalf("arka plan ack sonrası kuyruk boş olmalı, %d", c.Len())
	}
}

func TestBackgroundFlushRespectsBackoff(t *testing.T) {
	fc := newFakeCollector(t, scripted{status: 503, body: `{"title":"down"}`})
	c := newTestClient(t, fc, WithFlushInterval(10*time.Millisecond))
	if _, err := c.Track(context.Background(), Event{Name: "bg"}); err != nil {
		t.Fatal(err)
	}
	<-fc.received // ilk deneme 503
	time.Sleep(150 * time.Millisecond)
	// Backoff 1 sn olduğu için 150 ms içinde ikinci istek gitmemeli.
	if n := fc.count(); n != 1 {
		t.Fatalf("backoff sırasında yeniden deneme olmamalı, istek sayısı %d", n)
	}
	if c.Len() != 1 {
		t.Fatalf("olay kuyrukta kalmalı")
	}
}

func TestCloseFlushesAndBlocksTrack(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc, WithFlushInterval(time.Hour)) // arka plan pratikte hiç çalışmasın
	for i := 0; i < 3; i++ {
		if _, err := c.Track(context.Background(), Event{Name: "e"}); err != nil {
			t.Fatal(err)
		}
	}
	if err := c.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if fc.count() != 1 || countEvents(fc.request(0).Body) != 3 {
		t.Fatalf("Close son flush'ı yapmalı: istek=%d", fc.count())
	}
	if c.Len() != 0 || !c.Status().Closed {
		t.Fatalf("kapanış sonrası kuyruk boş ve closed=true olmalı")
	}
	if _, err := c.Track(context.Background(), Event{Name: "late"}); !errors.Is(err, ErrClosed) {
		t.Fatalf("kapanış sonrası Track ErrClosed vermeli: %v", err)
	}
	if _, err := c.Flush(context.Background()); !errors.Is(err, ErrClosed) {
		t.Fatalf("kapanış sonrası Flush ErrClosed vermeli: %v", err)
	}
	if err := c.Close(); err != nil {
		t.Fatalf("ikinci Close hatasız olmalı: %v", err)
	}
}

func TestCloseReportsUndelivered(t *testing.T) {
	fc := newFakeCollector(t, scripted{status: 503, body: `{"title":"down"}`})
	c := newTestClient(t, fc)
	if _, err := c.Track(context.Background(), Event{Name: "e"}); err != nil {
		t.Fatal(err)
	}
	if err := c.Close(); !errors.Is(err, ErrTemporary) {
		t.Fatalf("gönderilemeyen olay varsa Close ErrTemporary vermeli: %v", err)
	}
}

func TestConcurrentTrack(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc, WithQueueLimit(5000), WithBatchSize(MaxBatchSize))
	var wg sync.WaitGroup
	for g := 0; g < 8; g++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for i := 0; i < 100; i++ {
				if _, err := c.Track(context.Background(), Event{Name: "c"}); err != nil {
					t.Error(err)
					return
				}
			}
		}()
	}
	wg.Wait()
	if c.Len() != 800 {
		t.Fatalf("800 olay bekleniyordu, %d", c.Len())
	}
	res, err := c.Flush(context.Background())
	if err != nil || res.Accepted != 800 || c.Len() != 0 {
		t.Fatalf("Flush: err=%v res=%+v len=%d", err, res, c.Len())
	}
	if fc.count() != 2 {
		t.Fatalf("800 olay 500+300 iki batch olmalı, %d istek", fc.count())
	}
	seen := map[string]bool{}
	for i := 0; i < fc.count(); i++ {
		for _, e := range fc.request(i).Body["events"].([]any) {
			id := e.(map[string]any)["event_id"].(string)
			if seen[id] {
				t.Fatalf("event_id tekrar etti: %s", id)
			}
			seen[id] = true
		}
	}
}

func TestOccurredAtUsesInjectedClock(t *testing.T) {
	fc := newFakeCollector(t)
	fixed := time.Date(2026, 11, 3, 10, 0, 0, 123456789, time.FixedZone("TRT", 3*3600))
	c := newTestClient(t, fc, withNow(func() time.Time { return fixed }))
	ev, err := c.Track(context.Background(), Event{Name: "clock"})
	if err != nil {
		t.Fatal(err)
	}
	if ev.OccurredAt != "2026-11-03T07:00:00.123Z" {
		t.Fatalf("occurred_at UTC ms olmalı: %q", ev.OccurredAt)
	}
	explicit := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	ev, err = c.Track(context.Background(), Event{Name: "clock", OccurredAt: explicit})
	if err != nil || ev.OccurredAt != "2026-01-02T03:04:05.000Z" {
		t.Fatalf("açık OccurredAt korunmalı: %q %v", ev.OccurredAt, err)
	}
}

// lockedBuffer arka plan göndericisi ile testin aynı anda yazıp okuyabildiği günlük hedefidir.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// QA-B: proje anahtarı günlüğe yazılmaz. Bütün günlük yolları en ayrıntılı düzeyde çalıştırılır: izin yok, kabul, kuyruk
// taşması, kalıcı ret (sunucu anahtarı hata metninde geri yansıtsa bile), ağ hatası ve arka plan gönderim hatası.
func TestLogsAndErrorsNeverContainProjectKey(t *testing.T) {
	logs := &lockedBuffer{}
	logger := slog.New(slog.NewTextHandler(logs, &slog.HandlerOptions{Level: slog.LevelDebug}))
	assertClean := func(where, text string) {
		t.Helper()
		if strings.Contains(text, testKey) || strings.Contains(text, "pk_live_") {
			t.Fatalf("%s proje anahtarını içeriyor: %s", where, text)
		}
	}

	// 1) İzin yok: olay üretilmez, günlük satırı yazılır.
	fc := newFakeCollector(t,
		scripted{status: 202, body: `{"batch_id":"01B","accepted":1,"rejected":0}`},
		// Sunucu (ya da bir vekil) anahtarı hata metninde geri yansıtıyor.
		scripted{status: 401, body: `{"type":"urn:feralin:collect:problem:unauthorized","title":"Geçersiz anahtar","detail":"anahtar ` + testKey + ` tanınmadı"}`},
	)
	c := newTestClient(t, fc, WithLogger(logger), WithQueueLimit(2), WithBatchSize(10))
	c.SetConsent(Consent{})
	if ev, err := c.Track(context.Background(), Event{Name: "izinsiz"}); err != nil || ev != nil {
		t.Fatalf("izin yokken olay üretilmemeli: %v %v", ev, err)
	}
	c.SetConsent(Consent{Analytics: true})

	// 2) Kabul.
	if _, err := c.Track(context.Background(), Event{Name: "kabul"}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}

	// 3) Kuyruk taşması.
	for i := 0; i < 4; i++ {
		if _, err := c.Track(context.Background(), Event{Name: "tasma"}); err != nil {
			t.Fatal(err)
		}
	}

	// 4) Kalıcı ret: hata değeri ve günlük, sunucunun yansıttığı anahtarı taşımaz ama ret nedenini taşır.
	_, err := c.Flush(context.Background())
	if !errors.Is(err, ErrRejected) {
		t.Fatalf("401 için ErrRejected bekleniyordu: %v", err)
	}
	assertClean("ret hatası", err.Error())
	if !strings.Contains(err.Error(), "Geçersiz anahtar") || !strings.Contains(err.Error(), "gizlendi") {
		t.Fatalf("ret hatası nedeni maskelenmiş olarak taşımalı: %v", err)
	}

	// 5) Ağ hatası: istek başlığındaki anahtar taşıma hatasına sızmaz.
	fc.srv.Close()
	if _, err := c.Track(context.Background(), Event{Name: "ag"}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Flush(context.Background()); !errors.Is(err, ErrTemporary) {
		t.Fatalf("ağ hatasında ErrTemporary bekleniyordu: %v", err)
	} else {
		assertClean("ağ hatası", err.Error())
	}

	// 6) Arka plan gönderim hatası: kapalı sunucuya karşı periyodik gönderici günlüğe yazar.
	bg, err := NewClient(testKey, fc.srv.URL, WithConsent(Consent{Analytics: true}), WithFlushInterval(10*time.Millisecond), WithHTTPClient(fc.srv.Client()), WithLogger(logger))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := bg.Track(context.Background(), Event{Name: "arka_plan"}); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for !strings.Contains(logs.String(), "arka plan gönderim hatası") && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if err := bg.Close(); err != nil {
		assertClean("Close hatası", err.Error())
	}

	out := logs.String()
	for _, line := range []string{"izin yok, olay üretilmedi", "batch kabul edildi", "kuyruk sınırı aşıldı", "batch kalıcı olarak reddedildi", "arka plan gönderim hatası"} {
		if !strings.Contains(out, line) {
			t.Fatalf("günlük yolu çalışmadı: %q\n%s", line, out)
		}
	}
	assertClean("günlük", out)
	// Olay içeriği de günlüğe girmez: yalnız ad, sayı ve kimlikler.
	if strings.Contains(out, "anonymous_id") || strings.Contains(out, "properties") {
		t.Fatalf("günlük olay içeriği taşıyor:\n%s", out)
	}
}

// Kırpma sınırına denk gelen anahtar: özet 200 bayta kırpılır; maskeleme kırpmadan önce yapılmazsa anahtarın baş kısmı
// tam eşleşme bulunamadığı için maskesiz kalırdı. Anahtar özetin her konumunda denenir.
func TestProblemSummaryRedactsBeforeTruncation(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc)
	for offset := 0; offset <= maxProblemSummary+len(testKey); offset++ {
		body, err := json.Marshal(map[string]string{"title": strings.Repeat("x", offset) + testKey + " sonu"})
		if err != nil {
			t.Fatal(err)
		}
		got := c.problemSummary(body)
		if len(got) > maxProblemSummary {
			t.Fatalf("konum %d: özet %d bayt", offset, len(got))
		}
		// Anahtarın gizli kısmından (önekten sonraki 32 karakter) hiçbir parça kalmamalı.
		secret := strings.TrimPrefix(testKey, "pk_live_")
		for n := 6; n <= len(secret); n++ {
			if strings.Contains(got, secret[:n]) {
				t.Fatalf("konum %d: anahtarın ilk %d karakteri özette kaldı: %q", offset, n, got)
			}
		}
	}
	// Türkçe metin kırpılırken yarım UTF-8 dizisi bırakılmaz.
	long, _ := json.Marshal(map[string]string{"title": strings.Repeat("ş", 150)})
	if got := c.problemSummary(long); !utf8.ValidString(got) || len(got) > maxProblemSummary {
		t.Fatalf("kırpma geçersiz UTF-8 üretti: %q", got)
	}
}

func TestBackoffWaitHasHalfJitterAndRespectsRetryAfter(t *testing.T) {
	c := &Client{now: time.Now}
	seen := map[time.Duration]bool{}
	for range 50 {
		c.backoff = 0
		before := time.Now()
		c.noteFailure("")
		wait := c.backoffUntil.Sub(before)
		if c.backoff != time.Second {
			t.Fatalf("nominal geri çekilme değişmemeli: %v", c.backoff)
		}
		if wait < 500*time.Millisecond || wait > 1100*time.Millisecond {
			t.Fatalf("bekleme aralık dışında: %v", wait)
		}
		seen[wait.Truncate(time.Millisecond)] = true
	}
	if len(seen) < 2 {
		t.Fatal("bekleme dağılmalı")
	}
	c.backoff = 0
	before := time.Now()
	c.noteFailure("20")
	if wait := c.backoffUntil.Sub(before); wait < 20*time.Second {
		t.Fatalf("Retry-After alt sınırdır: %v", wait)
	}
}
