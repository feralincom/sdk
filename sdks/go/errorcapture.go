package feralin

import (
	"context"
	"errors"
	"fmt"
	"hash/fnv"
	"math/rand/v2"
	"reflect"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"unicode/utf8"
)

// `fr_error` sözleşmesi (X4): hata türü adı, temizlenmiş kısa mesaj, normalize edilmiş çerçevelerin özeti olan parmak izi ve en
// üst çerçeve. Ham yığın izi, dosya yolu, satır numarası ve kullanıcı verisi GİTMEZ. Kurallar Android (ErrorEvent.kt), React Native
// (signals.ts) ve Web SDK ile aynıdır; toplayıcı mesajı ayrıca temizler ve izin listesi dışı alanı düşürür.
const (
	// ErrorEventName hata olayının ayrılmış adıdır.
	ErrorEventName = "fr_error"
	// ErrorOriginHandled yakalanan (if err != nil) hata; varsayılan köken.
	ErrorOriginHandled = "handled"
	// ErrorOriginManual uygulamanın elle bildirdiği durum.
	ErrorOriginManual = "manual"
	// ErrorOriginUncaught kurtarılan panic (recover) gibi yakalanmamış hata.
	ErrorOriginUncaught = "uncaught_exception"

	errorMaxMessage      = 200
	errorMaxType         = 64
	errorMaxFrame        = 160
	errorMaxAppVersion   = 32
	errorFingerprintSize = 5
	errorMaxStackDepth   = 64
	defaultErrorMax      = 20
	defaultErrorPerPrint = 3
)

var (
	scrubURLRe    = regexp.MustCompile(`(?i)\b[a-z][a-z0-9+.-]*://[^\s"'<>]+`)
	scrubEmailRe  = regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`)
	scrubUUIDRe   = regexp.MustCompile(`(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b`)
	scrubTokenRe  = regexp.MustCompile(`\b[A-Za-z0-9_\-+/=]{24,}\b`)
	scrubNumberRe = regexp.MustCompile(`\+?\d[\d\s\-().]{5,}\d`)
	digitRunRe    = regexp.MustCompile(`\d+`)
)

// ErrorOptions CaptureError seçenekleridir. Sıfır değer: origin "handled", fatal false.
type ErrorOptions struct {
	// Origin hata kaynağı: ErrorOriginHandled, ErrorOriginManual ya da ErrorOriginUncaught.
	Origin string
	// Fatal hata süreci sonlandırdıysa true.
	Fatal bool
	// Identity olay başına kimlik (sunucu tarafında birden çok son kullanıcı işlenir).
	Identity
}

// WithAppVersion `fr_error` olaylarının app_version alanını ayarlar (≤32 karakter; uzunsa gönderilmez).
func WithAppVersion(version string) Option {
	return func(c *Client) { c.appVersion = version }
}

// WithErrorSampleRate hata olaylarının örnekleme oranını ayarlar (0..1, varsayılan 1). Sınırlar ayrıca uygulanır: süreç başına
// en çok 20 hata olayı, aynı parmak izi için en çok 3.
func WithErrorSampleRate(rate float64) Option {
	return func(c *Client) {
		c.errors = newErrorLimiter(rate, defaultErrorMax, defaultErrorPerPrint, rand.Float64)
	}
}

// ScrubErrorMessage mesajdan URL, e-posta, UUID, rakam içeren uzun belirteç ve en az 7 haneli sayı dizilerini çıkarır,
// boşlukları sadeleştirir ve 200 karaktere kırpar.
func ScrubErrorMessage(message string) string {
	text := scrubURLRe.ReplaceAllString(message, "[url]")
	text = scrubEmailRe.ReplaceAllString(text, "[email]")
	text = scrubUUIDRe.ReplaceAllString(text, "[id]")
	text = scrubTokenRe.ReplaceAllStringFunc(text, func(m string) string {
		if strings.ContainsAny(m, "0123456789") {
			return "[token]"
		}
		return m
	})
	text = scrubNumberRe.ReplaceAllStringFunc(text, func(m string) string {
		digits := 0
		for _, r := range m {
			if r >= '0' && r <= '9' {
				digits++
			}
		}
		if digits >= 7 {
			return "[num]"
		}
		return m
	})
	return truncateRunes(strings.Join(strings.Fields(text), " "), errorMaxMessage)
}

// ErrorFingerprint FNV-1a 64 (UTF-8 baytları üzerinde, 16 küçük harf onaltılı) özetidir: "tür|temel". Temel ilk beş çerçevedir;
// çerçeve yoksa rakam dizileri "#" yapılmış mesajdır.
func ErrorFingerprint(errorType string, frames []string, message string) string {
	basis := digitRunRe.ReplaceAllString(message, "#")
	if len(frames) > 0 {
		n := min(len(frames), errorFingerprintSize)
		basis = strings.Join(frames[:n], "|")
	}
	h := fnv.New64a()
	_, _ = h.Write([]byte(errorType + "|" + basis))
	return fmt.Sprintf("%016x", h.Sum64())
}

// ErrorProperties `fr_error` gövdesini kurar. frames normalize çerçevelerdir ("paket.İşlev", satır ve yol yok), en içteki önce.
func ErrorProperties(err error, origin string, fatal bool, appVersion string, frames []string) map[string]any {
	if origin == "" {
		origin = ErrorOriginHandled
	}
	errorType := errorTypeName(err)
	message := ""
	if err != nil {
		message = ScrubErrorMessage(err.Error())
	}
	props := map[string]any{
		"error_type":  errorType,
		"fingerprint": ErrorFingerprint(errorType, frames, message),
		"frame_count": min(len(frames), 1000),
		"handled":     origin == ErrorOriginHandled || origin == ErrorOriginManual,
		"fatal":       fatal,
		"origin":      origin,
	}
	if message != "" {
		props["message"] = message
	}
	if len(frames) > 0 {
		props["top_frame"] = truncateRunes(frames[0], errorMaxFrame)
	}
	if appVersion != "" && utf8.RuneCountInString(appVersion) <= errorMaxAppVersion {
		props["app_version"] = appVersion
	}
	return props
}

// CaptureError hatayı `fr_error` olayı olarak kuyruğa ekler. Çerçeveler çağrı anındaki yığından alınır (Go hatası yığın taşımaz),
// bu yüzden aynı işlevde yakalanan aynı türden hatalar aynı parmak izinde toplanır; SDK çerçeveleri atılır, uygulama çerçevesi varsa
// standart kütüphane çerçeveleri de atılır. Track ile aynı izin kuralı geçerlidir:
// izin yoksa (nil, nil). Sınır veya örnekleme olayı düşürürse de (nil, nil) döner. nil hata olay üretmez.
func (c *Client) CaptureError(ctx context.Context, err error, opts ErrorOptions) (*UtpEvent, error) {
	if err == nil {
		return nil, nil
	}
	frames := callerFrames(2)
	props := ErrorProperties(err, opts.Origin, opts.Fatal, c.appVersion, frames)
	if origin, _ := props["origin"].(string); !validErrorOrigin(origin) {
		props["origin"] = ErrorOriginManual
		props["handled"] = true
	}
	c.mu.Lock()
	consent := c.consent
	c.mu.Unlock()
	// İzin yoksa sınır sayacı tüketilmez: izin sonradan gelirse hatalar yine raporlanabilsin.
	if !consent.Analytics {
		return nil, nil
	}
	if !c.errors.allow(props["fingerprint"].(string)) {
		c.logger.Debug("feralin: fr_error sınırı ya da örnekleme, olay üretilmedi")
		return nil, nil
	}
	return c.Track(ctx, Event{Name: ErrorEventName, Properties: props, UserID: opts.UserID, AnonymousID: opts.AnonymousID, SessionID: opts.SessionID})
}

func validErrorOrigin(origin string) bool {
	return origin == ErrorOriginHandled || origin == ErrorOriginManual || origin == ErrorOriginUncaught
}

// errorTypeName %T değerini paket yolu ve * olmadan döndürür. fmt/errors sarmalayıcıları (wrapError, errorString, joinError) bilgi
// taşımadığı için zincirde uygulamaya ait ilk tür aranır; bulunmazsa en dıştaki tür kullanılır.
func errorTypeName(err error) string {
	if err == nil {
		return "Error"
	}
	for e := err; e != nil; e = errors.Unwrap(e) {
		t := reflect.TypeOf(e)
		for t.Kind() == reflect.Pointer {
			t = t.Elem()
		}
		if p := t.PkgPath(); p != "fmt" && p != "errors" {
			return typeLabel(e)
		}
	}
	return typeLabel(err)
}

func typeLabel(err error) string {
	name := strings.TrimLeft(fmt.Sprintf("%T", err), "*")
	if i := strings.LastIndex(name, "."); i >= 0 {
		name = name[i+1:]
	}
	name = truncateRunes(name, errorMaxType)
	if name == "" {
		return "Error"
	}
	return name
}

// callerFrames çağrı yığınını "paket.İşlev" biçimine çevirir: modül yolu, dosya ve satır gitmez. SDK çerçeveleri skip ile atlanır
// (callerFrames ve CaptureError); uygulama çerçevesi varsa standart kütüphane (runtime, testing, net/http ...) çerçeveleri de atılır.
func callerFrames(skip int) []string {
	pcs := make([]uintptr, errorMaxStackDepth)
	n := runtime.Callers(skip+1, pcs)
	iter := runtime.CallersFrames(pcs[:n])
	var all, app []string
	for {
		frame, more := iter.Next()
		fn := frame.Function
		if fn != "" {
			label := shortFunction(fn)
			all = append(all, label)
			if !isStdlibFunction(fn) {
				app = append(app, label)
			}
		}
		if !more {
			break
		}
	}
	if len(app) > 0 {
		return app
	}
	return all
}

// shortFunction "feralin.dev/x/pkg.(*T).Method" → "pkg.(*T).Method"; derleyicinin ürettiği .func1 ekleri parmak izini kararlı tutmak
// için atılmaz (aynı kod aynı adı üretir).
func shortFunction(fn string) string {
	if i := strings.LastIndex(fn, "/"); i >= 0 {
		fn = fn[i+1:]
	}
	return truncateRunes(fn, errorMaxFrame)
}

// isStdlibFunction paket yolunun ilk öğesinde nokta yoksa standart kütüphane sayar ("main" hariç).
func isStdlibFunction(fn string) bool {
	pkg := fn
	if slash := strings.LastIndex(pkg, "/"); slash >= 0 {
		if dot := strings.Index(pkg[slash:], "."); dot >= 0 {
			pkg = pkg[:slash+dot]
		}
	} else if dot := strings.Index(pkg, "."); dot >= 0 {
		pkg = pkg[:dot]
	}
	if pkg == "main" {
		return false
	}
	first, _, _ := strings.Cut(pkg, "/")
	return !strings.Contains(first, ".")
}

func truncateRunes(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

// errorLimiter hata fırtınası sınırıdır: süreç başına en çok maxEvents olay, aynı parmak izi için en çok maxPerFingerprint.
type errorLimiter struct {
	mu                sync.Mutex
	sampleRate        float64
	maxEvents         int
	maxPerFingerprint int
	random            func() float64
	total             int
	perFingerprint    map[string]int
}

func newErrorLimiter(sampleRate float64, maxEvents, maxPerFingerprint int, random func() float64) *errorLimiter {
	if sampleRate < 0 || sampleRate != sampleRate {
		sampleRate = 0
	}
	if sampleRate > 1 {
		sampleRate = 1
	}
	return &errorLimiter{sampleRate: sampleRate, maxEvents: maxEvents, maxPerFingerprint: maxPerFingerprint, random: random, perFingerprint: map[string]int{}}
}

func (l *errorLimiter) allow(fingerprint string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.total >= l.maxEvents {
		return false
	}
	if l.sampleRate < 1 && l.random() >= l.sampleRate {
		return false
	}
	if l.perFingerprint[fingerprint] >= l.maxPerFingerprint {
		return false
	}
	l.perFingerprint[fingerprint]++
	l.total++
	return true
}
