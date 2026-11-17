// Package feralin, Feralin UTP v1 toplayıcısına (services/collect, POST /v1/batch) sunucu tarafından
// olay gönderen resmî Go SDK'sıdır. Yalnız standart kütüphane kullanır.
//
// İlkeler (Web SDK ile tutarlı):
//   - consent.analytics=false ise olay üretilmez (Track nil, nil döner).
//   - At-least-once gönderim: 202 → ack; 4xx (429 hariç) → olaylar atılır; 5xx / 429 / ağ hatası → kuyrukta
//     tutulur ve üstel backoff (1 sn → 30 sn) ile yeniden denenir. Aynı batch aynı Idempotency-Key ile gider.
//   - Yalnız proje public anahtarı (pk_…) kullanılır; gizli anahtar (sk_…) reddedilir. tenant_id ve verified
//     alanları asla gönderilmez; bunları sunucu çözer.
package feralin

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	// SDKName olaylardaki sdk.name değeridir.
	SDKName = "feralin-go"
	// SDKVersion olaylardaki sdk.version değeridir; her yayınla birlikte güncellenir.
	SDKVersion = "0.1.0"
	// Platform UTP v1 platform enum değeridir.
	Platform = "go"
	// SchemaVersion UTP şema sürümüdür.
	SchemaVersion = 1

	// MaxBatchSize toplayıcının tek istekte kabul ettiği en fazla olay sayısıdır (batch.schema.json maxItems).
	MaxBatchSize = 500
	// DefaultBatchSize varsayılan toplu gönderim boyutudur.
	DefaultBatchSize = 100
	// DefaultQueueLimit bellek içi kuyruk sınırıdır; aşılırsa en eski olay atılır.
	DefaultQueueLimit = 1000
	// DefaultFlushInterval arka plan gönderim aralığıdır.
	DefaultFlushInterval = 2 * time.Second
	// DefaultHTTPTimeout enjekte edilmemiş http.Client için istek zaman aşımıdır.
	DefaultHTTPTimeout = 10 * time.Second

	closeTimeout    = 5 * time.Second
	minBackoff      = time.Second
	maxBackoff      = 30 * time.Second
	maxResponseBody = 64 << 10
	// Günlüğe ve hata değerine giren sunucu hata özetinin en büyük boyu (bayt).
	maxProblemSummary = 200
)

// Yapılandırma ve çalışma zamanı hataları; errors.Is ile ayrıştırılabilir.
var (
	ErrSecretKey         = errors.New("feralin: gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin")
	ErrInvalidProjectKey = errors.New("feralin: proje anahtarı pk_ ile başlamalı")
	ErrInvalidCollectURL = errors.New("feralin: collectURL http veya https şemalı mutlak adres olmalı")
	ErrClosed            = errors.New("feralin: istemci kapatıldı")
	// ErrRejected toplayıcı batch'i kalıcı olarak reddetti (4xx, 429 hariç); olaylar kuyruktan atıldı.
	ErrRejected = errors.New("feralin: batch kalıcı olarak reddedildi, olaylar atıldı")
	// ErrTemporary geçici hata (5xx, 429, ağ); olaylar kuyrukta tutuldu, aynı Idempotency-Key ile yeniden denenecek.
	ErrTemporary = errors.New("feralin: geçici gönderim hatası, olaylar kuyrukta tutuldu")
)

// Option NewClient yapılandırma seçeneğidir.
type Option func(*Client)

// WithHTTPClient istekleri yapan http.Client'ı enjekte eder (test, proxy, özel TLS).
func WithHTTPClient(hc *http.Client) Option {
	return func(c *Client) {
		if hc != nil {
			c.httpClient = hc
		}
	}
}

// WithFlushInterval arka plan gönderim aralığını ayarlar; 0 veya negatif değer arka plan göndericiyi kapatır
// (yalnız Flush/Close ile gönderim).
func WithFlushInterval(d time.Duration) Option {
	return func(c *Client) { c.flushInterval = d }
}

// WithBatchSize istek başına olay sayısını ayarlar (1..500).
func WithBatchSize(n int) Option {
	return func(c *Client) {
		if n < 1 {
			n = 1
		}
		if n > MaxBatchSize {
			n = MaxBatchSize
		}
		c.batchSize = n
	}
}

// WithQueueLimit bellek içi kuyruk sınırını ayarlar (en az 1); aşılırsa en eski olay atılır.
func WithQueueLimit(n int) Option {
	return func(c *Client) {
		if n >= 1 {
			c.queueLimit = n
		}
	}
}

// WithConsent başlangıç izin durumunu ayarlar. Varsayılan analytics=false'tur (consent-first).
func WithConsent(consent Consent) Option {
	return func(c *Client) { c.consent = consent }
}

// WithLogger hata ayıklama günlüğü için slog.Logger verir. Anahtar ve ham olay içeriği loglanmaz.
func WithLogger(l *slog.Logger) Option {
	return func(c *Client) {
		if l != nil {
			c.logger = l
		}
	}
}

// withNow testlerde zamanı sabitlemek için kullanılır.
func withNow(now func() time.Time) Option {
	return func(c *Client) {
		if now != nil {
			c.now = now
		}
	}
}

// FlushResult bir Flush çağrısının toplu sonucudur.
type FlushResult struct {
	// Sent bu çağrıda toplayıcıya iletilmeye çalışılan olay sayısı.
	Sent int
	// Accepted toplayıcının 202 ile kabul ettiği olay sayısı (idempotent tekrarda 0 olabilir).
	Accepted int
	// Rejected toplayıcının reddettiği veya 4xx ile atılan olay sayısı.
	Rejected int
	// BatchID son başarılı batch'in sunucu kimliği.
	BatchID string
	// Status son HTTP durum kodu (ağ hatasında 0).
	Status int
	// Retained geçici hata sonrası kuyrukta kalan olay sayısı.
	Retained int
}

// Status istemcinin anlık durumudur (debug/health amaçlı).
type Status struct {
	SDK      string
	Version  string
	Queued   int
	Dropped  uint64
	Consent  Consent
	UserID   string
	Closed   bool
	Backoff  time.Duration
	Endpoint string
}

type queuedEvent struct {
	id  string
	raw json.RawMessage
}

type batchBody struct {
	SentAt string            `json:"sent_at"`
	Events []json.RawMessage `json:"events"`
}

type ackBody struct {
	BatchID  string `json:"batch_id"`
	Accepted *int   `json:"accepted"`
	Rejected *int   `json:"rejected"`
}

type problemBody struct {
	Title  string `json:"title"`
	Detail string `json:"detail"`
}

// Client UTP v1 toplayıcısına olay gönderen, eşzamanlı kullanıma uygun istemcidir.
type Client struct {
	projectKey    string
	endpoint      string
	httpClient    *http.Client
	flushInterval time.Duration
	batchSize     int
	queueLimit    int
	logger        *slog.Logger
	now           func() time.Time
	ulid          *ulidGenerator
	// appVersion yalnız fr_error olaylarının app_version alanına girer; errors hata fırtınası sınırıdır.
	appVersion string
	errors     *errorLimiter

	// mu kuyruk, izin, kimlik ve backoff alanlarını korur.
	mu      sync.Mutex
	queue   []queuedEvent
	consent Consent
	userID  string
	// globals adı fr_ ile başlamayan her olaya eklenen özelliklerdir; SetGlobalProperties kopyala-değiştir ile yeniler.
	globals      map[string]any
	closed       bool
	dropped      uint64
	backoff      time.Duration
	backoffUntil time.Time

	// pinned sonucu bilinmeyen batch'tir: aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda
	// kaybolduysa araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
	pinned []queuedEvent

	// sendMu aynı anda tek gönderici olmasını sağlar (at-least-once + sabit Idempotency-Key).
	sendMu sync.Mutex

	wake chan struct{}
	stop chan struct{}
	done chan struct{}
}

// NewClient yeni bir istemci oluşturur. projectKey pk_ ile başlamalı; collectURL toplayıcı köküdür
// (ör. https://collect.example.com); /v1/batch yolu SDK tarafından eklenir.
func NewClient(projectKey, collectURL string, opts ...Option) (*Client, error) {
	key := strings.TrimSpace(projectKey)
	if strings.HasPrefix(key, "sk_") {
		return nil, ErrSecretKey
	}
	if !strings.HasPrefix(key, "pk_") || len(key) < 8 {
		return nil, ErrInvalidProjectKey
	}
	u, err := url.Parse(strings.TrimSpace(collectURL))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return nil, ErrInvalidCollectURL
	}

	c := &Client{
		projectKey:    key,
		endpoint:      strings.TrimRight(u.String(), "/") + "/v1/batch",
		httpClient:    &http.Client{Timeout: DefaultHTTPTimeout},
		flushInterval: DefaultFlushInterval,
		batchSize:     DefaultBatchSize,
		queueLimit:    DefaultQueueLimit,
		logger:        slog.New(slog.NewTextHandler(io.Discard, nil)),
		now:           time.Now,
		wake:          make(chan struct{}, 1),
		errors:        newErrorLimiter(1, defaultErrorMax, defaultErrorPerPrint, rand.Float64),
	}
	for _, opt := range opts {
		opt(c)
	}
	c.ulid = newULIDGenerator(c.now)

	if c.flushInterval > 0 {
		c.stop = make(chan struct{})
		c.done = make(chan struct{})
		go c.loop()
	}
	return c, nil
}

// SetConsent izin durumunu günceller. analytics=false ise bekleyen olaylar atılır ve yeni olay üretilmez.
func (c *Client) SetConsent(consent Consent) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.consent = consent
	if !consent.Analytics {
		c.queue = nil
		c.pinned = nil
	}
}

// Identify sonraki olaylar için varsayılan user_id'yi ayarlar (olay başına Event.UserID öncelidir).
// Boş değer varsayılanı kaldırır.
func (c *Client) Identify(userID string) error {
	if len(userID) > MaxIdentifierLength {
		return ErrInvalidIdentifier
	}
	c.mu.Lock()
	c.userID = userID
	c.mu.Unlock()
	return nil
}

// Track olayı doğrular, UTP v1 biçimine çevirir ve kuyruğa ekler; ağ çağrısı yapmaz.
// consent.analytics=false ise olay üretilmez ve (nil, nil) döner. Doğrulama hatalarında (nil, err) döner.
func (c *Client) Track(ctx context.Context, e Event) (*UtpEvent, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	c.mu.Lock()
	closed, consent, defaultUser, globals := c.closed, c.consent, c.userID, c.globals
	c.mu.Unlock()
	if closed {
		return nil, ErrClosed
	}
	if !consent.Analytics {
		c.logger.Debug("feralin: izin yok, olay üretilmedi", "event_name", e.Name)
		return nil, nil
	}
	if err := validateEvent(e); err != nil {
		return nil, err
	}

	occurred := e.OccurredAt
	if occurred.IsZero() {
		occurred = c.now()
	}
	userID := e.UserID
	if userID == "" {
		userID = defaultUser
	}
	ue := &UtpEvent{
		EventID:       c.ulid.New(),
		EventName:     e.Name,
		OccurredAt:    formatTime(occurred),
		Platform:      Platform,
		SchemaVersion: SchemaVersion,
		SDK:           SDKInfo{Name: SDKName, Version: SDKVersion},
		AnonymousID:   e.AnonymousID,
		UserID:        userID,
		SessionID:     e.SessionID,
		Consent:       consent,
		Context:       e.Context,
	}
	// Global özellikler sistem olaylarına (fr_) eklenmez: toplayıcı onların gövdesini kapalı sözleşmeyle denetler.
	props := withGlobals(e.Name, e.Properties, globals)
	if len(props) > 0 {
		ue.Properties = make(map[string]any, len(props))
		for k, v := range props {
			ue.Properties[k] = v
		}
		// fr_click yalnız açık reklam ölçümü izniyle gönderilir.
		if !consent.Advertising {
			delete(ue.Properties, attributionClickProperty)
		}
		if len(ue.Properties) == 0 {
			ue.Properties = nil
		}
	}
	// Serileştirme kuyruğa eklemeden önce yapılır; bozuk bir olay batch'i zehirleyemez.
	raw, err := json.Marshal(ue)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnserializable, err)
	}

	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil, ErrClosed
	}
	c.queue = append(c.queue, queuedEvent{id: ue.EventID, raw: raw})
	if over := len(c.queue) - c.queueLimit; over > 0 {
		c.queue = c.queue[over:]
		c.dropped += uint64(over)
		c.logger.Warn("feralin: kuyruk sınırı aşıldı, en eski olaylar atıldı", "dropped", over)
	}
	full := len(c.queue) >= c.batchSize
	c.mu.Unlock()

	if full {
		select {
		case c.wake <- struct{}{}:
		default:
		}
	}
	return ue, nil
}

// Flush kuyruktaki tüm olayları batch'ler hâlinde gönderir (backoff beklemez; açık çağrı niyet sayılır).
// 202 → ack; 4xx (429 hariç) → ErrRejected ve olaylar atılır; 5xx / 429 / ağ → ErrTemporary ve olaylar
// kuyrukta kalır. Kuyruk boşsa sıfır sonuç ve nil döner.
func (c *Client) Flush(ctx context.Context) (FlushResult, error) {
	c.mu.Lock()
	closed := c.closed
	c.mu.Unlock()
	if closed {
		return FlushResult{}, ErrClosed
	}
	return c.flush(ctx)
}

// Close arka plan göndericiyi durdurur ve kalan olayları en fazla 5 sn içinde göndermeyi dener.
// Birden çok çağrı güvenlidir. Gönderilemeyen olay kalırsa ilgili hata döner.
func (c *Client) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	c.mu.Unlock()

	if c.stop != nil {
		close(c.stop)
		<-c.done
	}
	ctx, cancel := context.WithTimeout(context.Background(), closeTimeout)
	defer cancel()
	_, err := c.flush(ctx)
	return err
}

// Len kuyrukta bekleyen olay sayısını döndürür.
func (c *Client) Len() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return len(c.queue)
}

// Status istemcinin anlık durumunu döndürür.
func (c *Client) Status() Status {
	c.mu.Lock()
	defer c.mu.Unlock()
	return Status{
		SDK:      SDKName,
		Version:  SDKVersion,
		Queued:   len(c.queue),
		Dropped:  c.dropped,
		Consent:  c.consent,
		UserID:   c.userID,
		Closed:   c.closed,
		Backoff:  c.backoff,
		Endpoint: c.endpoint,
	}
}

// loop arka plan göndericidir: aralık dolunca veya kuyruk batch boyutuna ulaşınca gönderir, backoff'a uyar.
func (c *Client) loop() {
	defer close(c.done)
	ticker := time.NewTicker(c.flushInterval)
	defer ticker.Stop()
	for {
		select {
		case <-c.stop:
			return
		case <-ticker.C:
		case <-c.wake:
		}
		c.mu.Lock()
		waiting := c.now().Before(c.backoffUntil)
		c.mu.Unlock()
		if waiting {
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), c.flushInterval+DefaultHTTPTimeout)
		if _, err := c.flush(ctx); err != nil {
			c.logger.Debug("feralin: arka plan gönderim hatası", "err", err)
		}
		cancel()
	}
}

func (c *Client) flush(ctx context.Context) (FlushResult, error) {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()

	var total FlushResult
	// Üretici sürekli ekliyorsa döngü sonsuz olmasın: en fazla kuyruk sınırı kadar olay + bir tur.
	maxRounds := c.queueLimit/c.batchSize + 2
	for round := 0; round < maxRounds; round++ {
		batch := c.nextBatch()
		if len(batch) == 0 {
			return total, nil
		}
		res, err := c.send(ctx, batch)
		total.Sent += res.Sent
		total.Accepted += res.Accepted
		total.Rejected += res.Rejected
		total.Status = res.Status
		if res.BatchID != "" {
			total.BatchID = res.BatchID
		}
		if err != nil {
			total.Retained = c.Len()
			return total, err
		}
	}
	total.Retained = c.Len()
	return total, nil
}

func (c *Client) nextBatch() []queuedEvent {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.pinned != nil {
		return c.pinned
	}
	n := len(c.queue)
	if n > c.batchSize {
		n = c.batchSize
	}
	out := make([]queuedEvent, n)
	copy(out, c.queue[:n])
	return out
}

func (c *Client) ack(ids []string) {
	set := make(map[string]struct{}, len(ids))
	for _, id := range ids {
		set[id] = struct{}{}
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.pinned = nil
	kept := c.queue[:0]
	for _, q := range c.queue {
		if _, ok := set[q.id]; !ok {
			kept = append(kept, q)
		}
	}
	for i := len(kept); i < len(c.queue); i++ {
		c.queue[i] = queuedEvent{}
	}
	c.queue = kept
}

// pin geçici hata sonrası batch'i sabitler. İstek sürerken izin geri çekildiyse olaylar çoktan silinmiştir, sabitlenmez.
func (c *Client) pin(batch []queuedEvent) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.consent.Analytics {
		c.pinned = batch
	}
}

// send tek bir batch'i gönderir. Idempotency-Key tüm event_id'lerin özetidir; aynı batch tekrarında aynıdır.
func (c *Client) send(ctx context.Context, batch []queuedEvent) (FlushResult, error) {
	n := len(batch)
	events := make([]json.RawMessage, n)
	ids := make([]string, n)
	for i, q := range batch {
		events[i] = q.raw
		ids[i] = q.id
	}
	body, err := json.Marshal(batchBody{SentAt: formatTime(c.now()), Events: events})
	if err != nil {
		return FlushResult{Sent: n}, fmt.Errorf("%w: %v", ErrUnserializable, err)
	}
	idempotencyKey := IdempotencyKeyFor(ids)

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.endpoint, bytes.NewReader(body))
	if err != nil {
		return FlushResult{Sent: n}, fmt.Errorf("%w: %v", ErrTemporary, err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, application/problem+json")
	req.Header.Set("X-Feralin-Project-Key", c.projectKey)
	req.Header.Set("Idempotency-Key", idempotencyKey)
	req.Header.Set("User-Agent", SDKName+"/"+SDKVersion)

	resp, err := c.httpClient.Do(req)
	if err != nil {
		c.pin(batch)
		c.noteFailure("")
		return FlushResult{Sent: n, Retained: n}, fmt.Errorf("%w: %s", ErrTemporary, c.redact(err.Error()))
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, maxResponseBody))

	switch {
	case resp.StatusCode == http.StatusAccepted:
		var ack ackBody
		_ = json.Unmarshal(raw, &ack)
		c.ack(ids)
		c.noteSuccess()
		res := FlushResult{Sent: n, Accepted: n, BatchID: ack.BatchID, Status: resp.StatusCode}
		if ack.Accepted != nil {
			res.Accepted = *ack.Accepted
		}
		if ack.Rejected != nil {
			res.Rejected = *ack.Rejected
		}
		c.logger.Debug("feralin: batch kabul edildi", "batch_id", ack.BatchID, "accepted", res.Accepted, "rejected", res.Rejected)
		return res, nil

	case resp.StatusCode >= 400 && resp.StatusCode < 500 && resp.StatusCode != http.StatusTooManyRequests:
		c.ack(ids)
		// Sunucunun ya da aradaki bir vekilin hata metni anahtarı geri yansıtabilir; günlüğe ve hataya maskelenmiş yazılır.
		problem := c.problemSummary(raw)
		c.logger.Warn("feralin: batch kalıcı olarak reddedildi", "status", resp.StatusCode, "problem", problem)
		return FlushResult{Sent: n, Rejected: n, Status: resp.StatusCode},
			fmt.Errorf("%w: HTTP %d: %s", ErrRejected, resp.StatusCode, problem)

	default:
		c.pin(batch)
		c.noteFailure(resp.Header.Get("Retry-After"))
		return FlushResult{Sent: n, Retained: n, Status: resp.StatusCode},
			fmt.Errorf("%w: HTTP %d", ErrTemporary, resp.StatusCode)
	}
}

// noteFailure üstel backoff'u ilerletir (1 sn → 30 sn); Retry-After verilmişse en az o kadar bekler.
// Yarım jitter: aynı anda yeniden başlayan süreçler toplayıcıya birlikte yüklenmez.
func (c *Client) noteFailure(retryAfter string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	next := c.backoff * 2
	if next < minBackoff {
		next = minBackoff
	}
	var floor time.Duration
	if retryAfter != "" {
		if secs, err := strconv.Atoi(strings.TrimSpace(retryAfter)); err == nil && secs > 0 {
			floor = time.Duration(secs) * time.Second
			if floor > next {
				next = floor
			}
		}
	}
	if next > maxBackoff {
		next = maxBackoff
	}
	if floor > maxBackoff {
		floor = maxBackoff
	}
	c.backoff = next
	wait := time.Duration(float64(next) * (0.5 + rand.Float64()*0.5))
	if wait < floor {
		wait = floor
	}
	c.backoffUntil = c.now().Add(wait)
}

func (c *Client) noteSuccess() {
	c.mu.Lock()
	c.backoff = 0
	c.backoffUntil = time.Time{}
	c.mu.Unlock()
}

// problemSummary RFC 7807 gövdesinden kısa, loglanabilir bir özet çıkarır (ham gövde sızdırılmaz).
// redact proje anahtarını metinden çıkarır. Anahtar yalnız istek başlığında taşınır; dışarıdan gelen metin (sunucu hata
// gövdesi, taşıma hatası) günlüğe ya da hata değerine girmeden önce buradan geçer.
func (c *Client) redact(s string) string {
	if c.projectKey == "" {
		return s
	}
	return strings.ReplaceAll(s, c.projectKey, "[proje anahtarı gizlendi]")
}

// problemSummary sunucu hata gövdesinin kısa özetidir. Önce maskelenir, sonra kırpılır: kırpma önce yapılsaydı sınıra denk
// gelen anahtarın baş kısmı tam eşleşme aranırken bulunamaz ve maskesiz kalırdı.
func (c *Client) problemSummary(raw []byte) string {
	var p problemBody
	if err := json.Unmarshal(raw, &p); err == nil && (p.Title != "" || p.Detail != "") {
		s := c.redact(strings.TrimSpace(strings.TrimSpace(p.Title) + " " + strings.TrimSpace(p.Detail)))
		if len(s) > maxProblemSummary {
			cut := maxProblemSummary
			for cut > 0 && !utf8.RuneStart(s[cut]) {
				cut--
			}
			s = s[:cut]
		}
		return s
	}
	return "problem+json yok"
}
