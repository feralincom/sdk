package feralin

import (
	"context"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"testing"
)

type paymentError struct{ msg string }

func (e *paymentError) Error() string { return e.msg }

var fingerprintRe = regexp.MustCompile(`^[0-9a-f]{16}$`)

// X4: CaptureError `fr_error` sözleşmesini üretir: tür adı paketsiz, mesaj temizlenmiş, ham yığın yok, parmak izi 16 hex.
func TestCaptureErrorContract(t *testing.T) {
	fc := newFakeCollector(t, scripted{status: 202, body: `{"batch_id":"01TESTBATCH0000000000000000","accepted":1,"rejected":0}`})
	c, err := NewClient(testKey, fc.srv.URL, WithConsent(Consent{Analytics: true}), WithFlushInterval(0), WithAppVersion("2.4.0"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	cause := &paymentError{msg: "kart reddedildi ali@example.com https://pay.example.com/x?t=1 id 550e8400-e29b-41d4-a716-446655440000 tel +90 532 123 45 67 oturum ab12cd34ef56gh78ij90kl12mn34"}
	ev, err := c.CaptureError(context.Background(), fmt.Errorf("ödeme: %w", cause), ErrorOptions{Identity: Identity{UserID: "user_42"}})
	if err != nil || ev == nil {
		t.Fatalf("CaptureError: ev=%v err=%v", ev, err)
	}
	p := ev.Properties
	if ev.EventName != ErrorEventName || ev.UserID != "user_42" {
		t.Fatalf("olay adı ya da kimlik hatalı: %+v", ev)
	}
	if p["error_type"] != "paymentError" {
		t.Fatalf("error_type = %v", p["error_type"])
	}
	msg, _ := p["message"].(string)
	for _, leak := range []string{"ali@example.com", "pay.example.com", "550e8400", "532 123", "ab12cd34"} {
		if strings.Contains(msg, leak) {
			t.Fatalf("mesajda kişisel veri kaldı (%s): %q", leak, msg)
		}
	}
	for _, tag := range []string{"[email]", "[url]", "[id]", "[num]", "[token]"} {
		if !strings.Contains(msg, tag) {
			t.Fatalf("mesajda %s yok: %q", tag, msg)
		}
	}
	if !fingerprintRe.MatchString(p["fingerprint"].(string)) {
		t.Fatalf("parmak izi biçimi: %v", p["fingerprint"])
	}
	top, _ := p["top_frame"].(string)
	if !strings.HasPrefix(top, "go.TestCaptureErrorContract") || strings.Contains(top, "/") || strings.Contains(top, ":") {
		t.Fatalf("top_frame normalize değil: %q", top)
	}
	if p["handled"] != true || p["fatal"] != false || p["origin"] != ErrorOriginHandled || p["app_version"] != "2.4.0" {
		t.Fatalf("bayraklar hatalı: %+v", p)
	}
	allowed := map[string]bool{"error_type": true, "message": true, "fingerprint": true, "top_frame": true, "frame_count": true, "app_version": true, "handled": true, "fatal": true, "origin": true}
	for k := range p {
		if !allowed[k] {
			t.Fatalf("sözleşme dışı alan: %s", k)
		}
	}
	if _, err := c.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	wire := fc.request(0).Body["events"].([]any)[0].(map[string]any)
	assertWireEvent(t, wire)
}

func TestCaptureErrorConsentLimitAndOrigin(t *testing.T) {
	fc := newFakeCollector(t)
	c, err := NewClient(testKey, fc.srv.URL, WithFlushInterval(0))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	ctx := context.Background()
	if ev, err := c.CaptureError(ctx, errors.New("x"), ErrorOptions{}); ev != nil || err != nil {
		t.Fatalf("izinsiz olay üretildi: %v %v", ev, err)
	}
	if ev, err := c.CaptureError(ctx, nil, ErrorOptions{}); ev != nil || err != nil {
		t.Fatalf("nil hata olay üretti: %v %v", ev, err)
	}
	c.SetConsent(Consent{Analytics: true})
	// Aynı parmak izi en çok 3 kez.
	sent := 0
	for i := 0; i < 5; i++ {
		if ev, _ := c.CaptureError(ctx, errors.New("aynı hata"), ErrorOptions{}); ev != nil {
			sent++
		}
	}
	if sent != 3 {
		t.Fatalf("parmak izi sınırı: %d", sent)
	}
	// Çerçeveler satırsızdır: aynı işlevde aynı türden hata aynı parmak izidir; farklı tür ayrı sayılır.
	ev, _ := c.CaptureError(ctx, &paymentError{msg: "çöktü"}, ErrorOptions{Origin: ErrorOriginUncaught, Fatal: true})
	if ev == nil || ev.Properties["handled"] != false || ev.Properties["fatal"] != true || ev.Properties["origin"] != ErrorOriginUncaught {
		t.Fatalf("uncaught bayrakları: %+v", ev)
	}
	ev, _ = c.CaptureError(ctx, fmt.Errorf("sarılı: %w", errors.ErrUnsupported), ErrorOptions{Origin: "window_onerror"})
	if ev == nil || ev.Properties["origin"] != ErrorOriginManual || ev.Properties["handled"] != true {
		t.Fatalf("bilinmeyen köken manual olmalı: %+v", ev)
	}
}

func TestErrorLimiterBounds(t *testing.T) {
	l := newErrorLimiter(1, defaultErrorMax, defaultErrorPerPrint, func() float64 { return 0.5 })
	allowed := 0
	for i := 0; i < 40; i++ {
		if l.allow(fmt.Sprintf("%016x", i)) {
			allowed++
		}
	}
	if allowed != defaultErrorMax {
		t.Fatalf("toplam sınır: %d", allowed)
	}
	half := newErrorLimiter(0.25, defaultErrorMax, defaultErrorPerPrint, func() float64 { return 0.5 })
	if half.allow("a") {
		t.Fatal("örnekleme dışı olay geçti")
	}
	if !newErrorLimiter(0.75, defaultErrorMax, defaultErrorPerPrint, func() float64 { return 0.5 }).allow("a") {
		t.Fatal("örnekleme içi olay düştü")
	}
}

func TestErrorFingerprintAndScrub(t *testing.T) {
	// FNV-1a 64: React Native ve Web SDK ile aynı özet ("" için çekirdek değer).
	h := ErrorFingerprint("TypeError", nil, "")
	if !fingerprintRe.MatchString(h) {
		t.Fatalf("biçim: %s", h)
	}
	if ErrorFingerprint("E", nil, "sipariş 123 bulunamadı") != ErrorFingerprint("E", nil, "sipariş 456 bulunamadı") {
		t.Fatal("çerçevesiz parmak izi rakamlardan bağımsız olmalı")
	}
	a := ErrorFingerprint("E", []string{"a", "b", "c", "d", "e", "f"}, "x")
	b := ErrorFingerprint("E", []string{"a", "b", "c", "d", "e", "g"}, "y")
	if a != b {
		t.Fatal("parmak izi ilk beş çerçeveyle sınırlı olmalı")
	}
	if got := ErrorFingerprint("", nil, ""); got != "af63f14c8602103b" {
		// fnv1a64("|") — sabit vektör diğer SDK'larla karşılaştırma içindir.
		t.Fatalf("FNV-1a vektörü: %s", got)
	}
	if got := ScrubErrorMessage("  sürüm 1.4.2   tamam  "); got != "sürüm 1.4.2 tamam" {
		t.Fatalf("kısa sürüm bozulmamalı: %q", got)
	}
	if got := ScrubErrorMessage("UnsupportedOperationExceptionHandler"); got != "UnsupportedOperationExceptionHandler" {
		t.Fatalf("rakamsız uzun ad bozulmamalı: %q", got)
	}
	if got := ScrubErrorMessage(strings.Repeat("ş", 300)); len([]rune(got)) != 200 {
		t.Fatalf("200 karakter sınırı: %d", len([]rune(got)))
	}
	if errorTypeName(errors.New("x")) != "errorString" {
		t.Fatalf("errors.New türü: %s", errorTypeName(errors.New("x")))
	}
	if !isStdlibFunction("net/http.(*conn).serve") || !isStdlibFunction("runtime.goexit") || isStdlibFunction("main.handler") || isStdlibFunction("example.com/app/pay.Charge") {
		t.Fatal("standart kütüphane sezgisi hatalı")
	}
}
