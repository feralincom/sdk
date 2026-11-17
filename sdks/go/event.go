package feralin

import (
	"errors"
	"fmt"
	"hash/fnv"
	"regexp"
	"sort"
	"strings"
	"time"
)

// UTP v1 sözleşmesi: packages/schemas/utp/v1/event.schema.json ile birebir.
// tenant_id, project_id ve verified alanları istemciden gönderilmez; sunucu anahtar bağlamından çözer.

const (
	// MaxEventNameLength şemadaki event_name maxLength değeridir.
	MaxEventNameLength = 100
	// MaxProperties şemadaki properties.maxProperties değeridir.
	MaxProperties = 100
	// MaxIdentifierLength user_id / anonymous_id / session_id için şema üst sınırıdır.
	MaxIdentifierLength = 128

	attributionClickProperty = "fr_click"
)

// IdempotencyKeyFor Web, Node, .NET, Android ve Flutter SDK'larıyla aynı anahtarı üretir: sıralı tüm event_id'lerin
// FNV-1a 64 özeti ve olay sayısı. Sıradan bağımsızdır; farklı içerik farklı anahtar üretir.
func IdempotencyKeyFor(eventIDs []string) string {
	sorted := append([]string(nil), eventIDs...)
	sort.Strings(sorted)
	hash := fnv.New64a()
	_, _ = hash.Write([]byte(strings.Join(sorted, ",")))
	return fmt.Sprintf("%016x-%d", hash.Sum64(), len(sorted))
}

var (
	eventNameRe   = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)
	propertyKeyRe = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9_]{0,63}$`)
)

// Doğrulama hataları; errors.Is ile ayrıştırılabilir.
var (
	ErrInvalidEventName   = errors.New("feralin: event_name snake_case olmalı (^[a-z][a-z0-9_]*$, en fazla 100 karakter)")
	ErrInvalidPropertyKey = errors.New("feralin: properties anahtarı ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ desenine uymalı")
	ErrTooManyProperties  = errors.New("feralin: properties en fazla 100 anahtar içerebilir")
	ErrInvalidIdentifier  = errors.New("feralin: user_id, anonymous_id ve session_id en fazla 128 karakter olabilir")
	ErrUnserializable     = errors.New("feralin: olay JSON'a dönüştürülemedi")
)

// Consent UTP v1 izin anlık görüntüsüdür. Analytics false ise hiçbir olay üretilmez.
// Server SDK'da izin bilgisi müşteri uygulamasından geçirilir (consent passthrough); tüm alanlar açıkça gönderilir.
type Consent struct {
	Analytics       bool `json:"analytics"`
	Advertising     bool `json:"advertising"`
	Personalization bool `json:"personalization"`
	SessionReplay   bool `json:"session_replay"`
}

// Screen isteğe bağlı ekran bilgisidir (server SDK'da nadiren kullanılır).
type Screen struct {
	Width  int `json:"width"`
	Height int `json:"height"`
}

// AppInfo müşteri uygulamasının sürüm bilgisidir.
type AppInfo struct {
	Version string `json:"version,omitempty"`
	Build   string `json:"build,omitempty"`
}

// Context şemadaki context nesnesidir; yalnız dolu alanlar gönderilir.
type Context struct {
	PageURL   string   `json:"page_url,omitempty"`
	PageTitle string   `json:"page_title,omitempty"`
	Referrer  string   `json:"referrer,omitempty"`
	Locale    string   `json:"locale,omitempty"`
	Timezone  string   `json:"timezone,omitempty"`
	Screen    *Screen  `json:"screen,omitempty"`
	App       *AppInfo `json:"app,omitempty"`
}

// Event, Track'e verilen giriş verisidir. Sunucu tarafında birden çok son kullanıcı işlendiği için
// kimlikler olay başına verilebilir; UserID boşsa Identify ile ayarlanan varsayılan kullanılır.
type Event struct {
	// Name snake_case olay adı (ör. order_completed).
	Name string
	// Properties en fazla 100 anahtar; anahtarlar ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ desenine uymalı. PII koymayın.
	Properties map[string]any
	// UserID müşteri uygulamasının kendi kullanıcı kimliği (PII olmamalı).
	UserID string
	// AnonymousID istemciden (ör. Web SDK çerezi) aktarılan anonim kimlik.
	AnonymousID string
	// SessionID istemci oturum kimliği.
	SessionID string
	// OccurredAt olayın gerçekleşme zamanı; sıfır değer ise şimdi (UTC) kullanılır.
	OccurredAt time.Time
	// Context isteğe bağlı bağlam.
	Context *Context
}

// SDKInfo olayın hangi SDK ile üretildiğini belirtir.
type SDKInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

// UtpEvent tel üzerinde giden UTP v1 olayıdır (event.schema.json alan adlarıyla birebir).
type UtpEvent struct {
	EventID       string         `json:"event_id"`
	EventName     string         `json:"event_name"`
	OccurredAt    string         `json:"occurred_at"`
	Platform      string         `json:"platform"`
	SchemaVersion int            `json:"schema_version"`
	SDK           SDKInfo        `json:"sdk"`
	AnonymousID   string         `json:"anonymous_id,omitempty"`
	UserID        string         `json:"user_id,omitempty"`
	SessionID     string         `json:"session_id,omitempty"`
	Properties    map[string]any `json:"properties,omitempty"`
	Consent       Consent        `json:"consent"`
	Context       *Context       `json:"context,omitempty"`
}

// validateEvent şema kurallarını istemci tarafında uygular; sunucu yine de doğrular.
func validateEvent(e Event) error {
	if e.Name == "" || len(e.Name) > MaxEventNameLength || !eventNameRe.MatchString(e.Name) {
		return ErrInvalidEventName
	}
	if len(e.Properties) > MaxProperties {
		return ErrTooManyProperties
	}
	for k := range e.Properties {
		if !propertyKeyRe.MatchString(k) {
			return ErrInvalidPropertyKey
		}
	}
	if len(e.UserID) > MaxIdentifierLength || len(e.AnonymousID) > MaxIdentifierLength || len(e.SessionID) > MaxIdentifierLength {
		return ErrInvalidIdentifier
	}
	return nil
}

// formatTime UTC RFC3339 milisaniye hassasiyetinde biçimler (ör. 2026-11-03T10:00:00.123Z).
func formatTime(t time.Time) string {
	return t.UTC().Format("2006-01-02T15:04:05.000Z07:00")
}
