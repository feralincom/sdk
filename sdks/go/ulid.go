package feralin

import (
	"crypto/rand"
	"sync"
	"time"
)

// crockford, ULID spesifikasyonundaki base32 alfabesidir (I, L, O, U yok).
const crockford = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

// ulidGenerator aynı milisaniye içinde monotonik artan ULID üretir; eşzamanlı çağrılara karşı kilitlidir.
// Web SDK (packages/sdk-web/src/ulid.ts) ile aynı düzen: 10 karakter zaman + 16 adet 5 bitlik rastgele basamak.
type ulidGenerator struct {
	mu       sync.Mutex
	now      func() time.Time
	lastMs   int64
	lastRand [16]byte // her eleman 0..31 arası tek bir base32 basamağı (toplam 80 bit)
}

func newULIDGenerator(now func() time.Time) *ulidGenerator {
	if now == nil {
		now = time.Now
	}
	return &ulidGenerator{now: now}
}

// New 26 karakterlik ULID döndürür. Aynı ms içinde (veya saat geri giderse) son değer bir artırılır,
// böylece sıralama korunur; rastgele kısım taşarsa bir sonraki ms kullanılır.
func (g *ulidGenerator) New() string {
	g.mu.Lock()
	defer g.mu.Unlock()

	ms := g.now().UnixMilli()
	if ms > g.lastMs {
		g.fillRandom()
	} else {
		ms = g.lastMs
		if !g.increment() {
			ms++
			g.fillRandom()
		}
	}
	g.lastMs = ms

	var out [26]byte
	t := uint64(ms)
	for i := 9; i >= 0; i-- {
		out[i] = crockford[t&31]
		t >>= 5
	}
	for i, v := range g.lastRand {
		out[10+i] = crockford[v]
	}
	return string(out[:])
}

func (g *ulidGenerator) fillRandom() {
	var buf [16]byte
	// crypto/rand.Read Go 1.24+ sürümlerinde hata döndürmez; imza uyumu için sonuç yine de yok sayılmaz.
	if _, err := rand.Read(buf[:]); err != nil {
		n := uint64(time.Now().UnixNano())
		for i := range buf {
			buf[i] = byte(n >> (uint(i) * 4 % 64))
		}
	}
	for i := range buf {
		g.lastRand[i] = buf[i] & 31
	}
}

// increment rastgele kısmı base32 düzeninde bir artırır; tüm basamaklar taşarsa false döner.
func (g *ulidGenerator) increment() bool {
	for i := 15; i >= 0; i-- {
		if g.lastRand[i] < 31 {
			g.lastRand[i]++
			return true
		}
		g.lastRand[i] = 0
	}
	return false
}

// isULID metnin 26 karakterlik Crockford base32 ULID biçiminde olup olmadığını denetler.
func isULID(s string) bool {
	if len(s) != 26 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		valid := false
		for j := 0; j < len(crockford); j++ {
			if crockford[j] == c {
				valid = true
				break
			}
		}
		if !valid {
			return false
		}
	}
	// İlk karakter en fazla '7' olabilir (48 bit zaman damgası 50 bite sığar).
	return s[0] <= '7'
}
