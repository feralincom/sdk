package feralin

import (
	"context"
	"math"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

// UTP §8.2 kimlik yöntemleri: Group (`fr_group`), SetUserProperties (`fr_user_properties`) ve global özellikler.
//
// Kurallar bütün SDK'larda ve toplayıcıda (services/collect/internal/httpapi/profile_filter.go) aynıdır:
//   - Anahtar ^[a-zA-Z][a-zA-Z0-9_]{0,63}$; çağrı başına en çok 50 özellik.
//   - Değer dizge (en çok 256 karakter, kontrol karakteri yok, e-posta biçiminde değil), sonlu sayı ya da bool; nesne, dilim ve nil düşer.
//   - Doğrulama alanları (verified, receipt vb.) düşer: istemci doğrulama beyan edemez.
//   - Kişisel veriye benzeyen anahtar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) düşer.
//
// Toplayıcı ayrıca projenin izin listesini uygular; liste boşsa olay sayılır ama özellik saklanmaz.
const (
	// GroupEventName grup olayı adıdır (React Native, Unity ve öteki SDK'larla aynı).
	GroupEventName = "fr_group"
	// UserPropertiesEventName kullanıcı özellikleri olayı adıdır.
	UserPropertiesEventName = "fr_user_properties"
	// MaxProfileProperties çağrı başına ve global haritada en çok özellik sayısıdır.
	MaxProfileProperties = 50
	// MaxProfileValueLength dizge değerin en çok karakter sayısıdır.
	MaxProfileValueLength = 256
	// MaxGroupIDLength grup kimliğinin en çok karakter sayısıdır.
	MaxGroupIDLength = 128

	systemEventPrefix = "fr_"
)

var (
	profileEmailRe      = regexp.MustCompile(`[^\s@]+@[^\s@]+\.[^\s@]+`)
	profileReservedKeys = map[string]struct{}{
		"verified": {}, "verification": {}, "verification_source": {}, "receipt_provider": {}, "receipt_digest": {}, "receipt": {},
	}
	// Toplayıcıdaki piiTokens, piiFragments ve piiExact listeleriyle birebir.
	piiTokens = map[string]struct{}{
		"email": {}, "mail": {}, "phone": {}, "tel": {}, "telephone": {}, "mobile": {}, "msisdn": {}, "gsm": {},
		"ip": {}, "ipv4": {}, "ipv6": {}, "ssn": {}, "tckn": {}, "passport": {}, "password": {}, "iban": {},
		"address": {}, "adres": {}, "eposta": {}, "telefon": {}, "soyad": {}, "surname": {}, "firstname": {},
		"lastname": {}, "fullname": {}, "birthdate": {}, "birthday": {}, "dob": {},
	}
	piiFragments = []string{"email", "phonenumber", "ipaddress", "firstname", "lastname", "fullname", "surname", "soyad", "eposta", "telefon", "password", "birthdate"}
	piiExact     = map[string]struct{}{"name": {}, "username": {}, "displayname": {}, "isim": {}, "ad": {}}
)

// Identity sunucu tarafında kimliğin çağrı başına verilmesidir; UserID boşsa Identify ile ayarlanan varsayılan kullanılır.
type Identity struct {
	UserID      string
	AnonymousID string
	SessionID   string
}

func profileKeyTokens(key string) []string {
	var b strings.Builder
	runes := []rune(key)
	for i, r := range runes {
		if i > 0 && unicode.IsUpper(r) && (unicode.IsLower(runes[i-1]) || unicode.IsDigit(runes[i-1])) {
			b.WriteByte('_')
		}
		b.WriteRune(unicode.ToLower(r))
	}
	var tokens []string
	for _, token := range strings.Split(b.String(), "_") {
		if token != "" {
			tokens = append(tokens, token)
		}
	}
	return tokens
}

// IsPIILikeKey anahtarın kişisel veriye benzeyip benzemediğini söyler (toplayıcıyla aynı kural).
func IsPIILikeKey(key string) bool {
	tokens := profileKeyTokens(key)
	for _, token := range tokens {
		if _, denied := piiTokens[token]; denied {
			return true
		}
	}
	joined := strings.Join(tokens, "")
	if _, denied := piiExact[joined]; denied {
		return true
	}
	for _, fragment := range piiFragments {
		if strings.Contains(joined, fragment) {
			return true
		}
	}
	return false
}

func hasControlRune(text string) bool {
	for _, r := range text {
		if unicode.IsControl(r) {
			return true
		}
	}
	return false
}

// profileValue değeri sözleşmeye göre denetler; JSON'a doğru giden tek türe (string, float64/int türleri, bool) indirger.
func profileValue(value any) (any, bool) {
	switch v := value.(type) {
	case string:
		if utf8.RuneCountInString(v) > MaxProfileValueLength || hasControlRune(v) || profileEmailRe.MatchString(v) {
			return nil, false
		}
		return v, true
	case bool:
		return v, true
	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64:
		return v, true
	case float32:
		return v, !math.IsNaN(float64(v)) && !math.IsInf(float64(v), 0)
	case float64:
		return v, !math.IsNaN(v) && !math.IsInf(v, 0)
	}
	return nil, false
}

func validProfileKey(key string) bool {
	if !propertyKeyRe.MatchString(key) || IsPIILikeKey(key) {
		return false
	}
	_, reserved := profileReservedKeys[key]
	return !reserved
}

// SanitizeProfileProperties özellikleri sözleşmeye indirger; geçersiz anahtar ve değer düşer. Sınırı aşan fazlalık anahtar
// sözlük sırasına göre düşer (map sırası rastgele olduğundan sonuç böylece deterministiktir).
func SanitizeProfileProperties(props map[string]any) map[string]any {
	out := map[string]any{}
	keys := make([]string, 0, len(props))
	for key := range props {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if len(out) >= MaxProfileProperties {
			break
		}
		if !validProfileKey(key) {
			continue
		}
		if value, ok := profileValue(props[key]); ok {
			out[key] = value
		}
	}
	return out
}

// ValidGroupID grup kimliği kuralıdır: 1-128 karakter, boşluktan ibaret değil, `@` ve kontrol karakteri içermez.
func ValidGroupID(id string) bool {
	if strings.TrimSpace(id) == "" || utf8.RuneCountInString(id) > MaxGroupIDLength {
		return false
	}
	return !strings.ContainsRune(id, '@') && !hasControlRune(id)
}

// SetGlobalProperties global özellikleri birleştirir: nil değer anahtarı siler. Kimlik yöntemleriyle aynı temizlik kuralları
// uygulanır; toplam en çok 50 anahtar, fazlası yok sayılır. Adı `fr_` ile başlamayan her olaya Track anında eklenir; olayın
// aynı anahtardaki özelliği globali ezer.
func (c *Client) SetGlobalProperties(props map[string]any) {
	additions := map[string]any{}
	var removals []string
	for key, value := range props {
		if value == nil {
			removals = append(removals, key)
			continue
		}
		additions[key] = value
	}
	clean := SanitizeProfileProperties(additions)
	if dropped := len(additions) - len(clean); dropped > 0 {
		c.logger.Warn("feralin: global özelliklerin bir kısmı sözleşmeye uymadığı için düştü", "dropped", dropped)
	}
	keys := make([]string, 0, len(clean))
	for key := range clean {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	c.mu.Lock()
	defer c.mu.Unlock()
	// Kopyala-değiştir: Track anlık görüntüyü kilitsiz okur.
	next := make(map[string]any, len(c.globals)+len(clean))
	for key, value := range c.globals {
		next[key] = value
	}
	for _, key := range removals {
		delete(next, key)
	}
	for _, key := range keys {
		if _, exists := next[key]; !exists && len(next) >= MaxProfileProperties {
			c.logger.Warn("feralin: global özellik sınırı dolu, yeni anahtar yok sayıldı", "limit", MaxProfileProperties)
			continue
		}
		next[key] = clean[key]
	}
	c.globals = next
}

// ClearGlobalProperties bütün global özellikleri siler.
func (c *Client) ClearGlobalProperties() {
	c.mu.Lock()
	c.globals = nil
	c.mu.Unlock()
}

// Group kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve temizlenmiş özellikler. Grup
// kimliği kurala uymazsa olay üretilmez ve (nil, nil) döner (izinsiz Track ile aynı). Toplayıcı yalnız projenin izin
// listesindeki özellikleri saklar.
func (c *Client) Group(ctx context.Context, groupID string, traits map[string]any, who Identity) (*UtpEvent, error) {
	if !ValidGroupID(groupID) {
		c.logger.Warn("feralin: fr_group: geçersiz group_id, olay üretilmedi")
		return nil, nil
	}
	props := SanitizeProfileProperties(traits)
	props["group_id"] = groupID
	return c.Track(ctx, Event{Name: GroupEventName, Properties: props, UserID: who.UserID, AnonymousID: who.AnonymousID, SessionID: who.SessionID})
}

// SetUserProperties kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Geçerli özellik kalmazsa olay üretilmez ve
// (nil, nil) döner. Toplayıcı yalnız projenin izin listesindeki anahtarları saklar (liste boşsa olay sayılır, özellik saklanmaz).
func (c *Client) SetUserProperties(ctx context.Context, props map[string]any, who Identity) (*UtpEvent, error) {
	clean := SanitizeProfileProperties(props)
	if len(clean) == 0 {
		c.logger.Warn("feralin: fr_user_properties: geçerli özellik yok, olay üretilmedi")
		return nil, nil
	}
	return c.Track(ctx, Event{Name: UserPropertiesEventName, Properties: clean, UserID: who.UserID, AnonymousID: who.AnonymousID, SessionID: who.SessionID})
}

// withGlobals global özellikleri olay özelliklerine ekler; olayın kendi anahtarı önceliklidir, toplam MaxProperties'i aşmaz.
func withGlobals(name string, props, globals map[string]any) map[string]any {
	if len(globals) == 0 || strings.HasPrefix(name, systemEventPrefix) {
		return props
	}
	merged := make(map[string]any, len(props)+len(globals))
	for key, value := range props {
		merged[key] = value
	}
	keys := make([]string, 0, len(globals))
	for key := range globals {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		if _, exists := merged[key]; exists || len(merged) >= MaxProperties {
			continue
		}
		merged[key] = globals[key]
	}
	return merged
}
