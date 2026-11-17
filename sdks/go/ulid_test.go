package feralin

import (
	"regexp"
	"sort"
	"sync"
	"testing"
	"time"
)

var ulidRe = regexp.MustCompile(`^[0-7][0-9A-HJKMNP-TV-Z]{25}$`)

func TestULIDFormat(t *testing.T) {
	g := newULIDGenerator(nil)
	for i := 0; i < 1000; i++ {
		id := g.New()
		if !ulidRe.MatchString(id) {
			t.Fatalf("ULID biçimi hatalı: %q", id)
		}
		if !isULID(id) {
			t.Fatalf("isULID kendi ürettiğini reddetti: %q", id)
		}
	}
	for _, bad := range []string{"", "01ARZ3NDEKTSV4RRFFQ69G5FAV1", "01ARZ3NDEKTSV4RRFFQ69G5FA", "01ARZ3NDEKTSV4RRFFQ69G5FAI", "81ARZ3NDEKTSV4RRFFQ69G5FAV"} {
		if isULID(bad) {
			t.Fatalf("geçersiz ULID kabul edildi: %q", bad)
		}
	}
}

func TestULIDTimestampPrefix(t *testing.T) {
	fixed := time.UnixMilli(1_762_164_000_000) // 2026-11-03T10:00:00Z
	g := newULIDGenerator(func() time.Time { return fixed })
	id := g.New()
	// 10 karakterlik zaman kısmı base32 ile geri çözülerek doğrulanır.
	var ms uint64
	for i := 0; i < 10; i++ {
		idx := -1
		for j := 0; j < len(crockford); j++ {
			if crockford[j] == id[i] {
				idx = j
				break
			}
		}
		if idx < 0 {
			t.Fatalf("zaman karakteri alfabede yok: %c", id[i])
		}
		ms = ms*32 + uint64(idx)
	}
	if int64(ms) != fixed.UnixMilli() {
		t.Fatalf("zaman kısmı %d, beklenen %d", ms, fixed.UnixMilli())
	}
}

func TestULIDMonotonicWithinSameMillisecond(t *testing.T) {
	fixed := time.UnixMilli(1_762_164_000_000)
	g := newULIDGenerator(func() time.Time { return fixed })
	ids := make([]string, 5000)
	for i := range ids {
		ids[i] = g.New()
	}
	for i := 1; i < len(ids); i++ {
		if ids[i-1] >= ids[i] {
			t.Fatalf("monotonik değil: %q >= %q", ids[i-1], ids[i])
		}
		if ids[i-1][:10] != ids[i][:10] {
			t.Fatalf("aynı ms içinde zaman kısmı değişmemeli: %q %q", ids[i-1], ids[i])
		}
	}
}

func TestULIDMonotonicWhenClockGoesBackwards(t *testing.T) {
	now := time.UnixMilli(1_762_164_000_000)
	g := newULIDGenerator(func() time.Time { return now })
	first := g.New()
	now = now.Add(-10 * time.Second) // saat geri gitti
	second := g.New()
	if second <= first {
		t.Fatalf("saat geri gidince sıralama bozuldu: %q <= %q", second, first)
	}
}

func TestULIDRandomOverflowAdvancesTime(t *testing.T) {
	fixed := time.UnixMilli(1_762_164_000_000)
	g := newULIDGenerator(func() time.Time { return fixed })
	first := g.New()
	for i := range g.lastRand {
		g.lastRand[i] = 31 // rastgele kısım dolu: bir sonraki artış taşar
	}
	next := g.New()
	if next <= first {
		t.Fatalf("taşma sonrası sıralama bozuldu")
	}
	if next[:10] == first[:10] {
		t.Fatalf("taşmada zaman kısmı bir ms ilerlemeli")
	}
}

func TestULIDConcurrentUnique(t *testing.T) {
	g := newULIDGenerator(nil)
	var mu sync.Mutex
	var wg sync.WaitGroup
	all := make([]string, 0, 8*500)
	for w := 0; w < 8; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			local := make([]string, 0, 500)
			for i := 0; i < 500; i++ {
				local = append(local, g.New())
			}
			mu.Lock()
			all = append(all, local...)
			mu.Unlock()
		}()
	}
	wg.Wait()
	sort.Strings(all)
	for i := 1; i < len(all); i++ {
		if all[i-1] == all[i] {
			t.Fatalf("eşzamanlı üretimde tekrar: %q", all[i])
		}
	}
}
