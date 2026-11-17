package feralin

import (
	"context"
	"fmt"
	"math"
	"reflect"
	"strings"
	"sync"
	"testing"
)

func TestIsPIILikeKey(t *testing.T) {
	for _, key := range []string{"email", "userEmail", "email_address", "phone", "phoneNumber", "mobile", "ip", "userIP", "ipv4",
		"ip_address", "first_name", "lastName", "fullname", "surname", "ad_soyad", "soyadi", "name", "userName", "displayName",
		"isim", "ad", "home_address", "tckn", "ssn", "password", "birthdate", "dob", "iban", "eposta", "telefon_no"} {
		if !IsPIILikeKey(key) {
			t.Errorf("%s kişisel veri sayılmalıydı", key)
		}
	}
	for _, key := range []string{"plan", "tier", "zip_code", "hotel", "membership", "ad_network", "plan_name", "company_size"} {
		if IsPIILikeKey(key) {
			t.Errorf("%s kişisel veri sayılmamalıydı", key)
		}
	}
}

func TestSanitizeProfileProperties(t *testing.T) {
	got := SanitizeProfileProperties(map[string]any{
		"plan": "pro", "tier": 2, "ratio": 0.5, "beta": true,
		"verified": true, "receipt": "x", "email": "a@b.co", "note": "iletişim a@b.co",
		"long": strings.Repeat("x", 257), "ok_long": strings.Repeat("x", 256),
		"nested": map[string]any{"a": 1}, "items": []int{1, 2}, "nothing": nil,
		"nan": math.NaN(), "inf": math.Inf(1), "ctrl": "a\nb", "1bad": "x",
	})
	want := map[string]any{"plan": "pro", "tier": 2, "ratio": 0.5, "beta": true, "ok_long": strings.Repeat("x", 256)}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("temizlik: %v, beklenen %v", got, want)
	}
	many := map[string]any{}
	for i := 0; i < 60; i++ {
		many[fmt.Sprintf("k%02d", i)] = i
	}
	if n := len(SanitizeProfileProperties(many)); n != MaxProfileProperties {
		t.Fatalf("sınır %d, beklenen %d", n, MaxProfileProperties)
	}
}

func flushedEvents(t *testing.T, c *Client, fc *fakeCollector) []map[string]any {
	t.Helper()
	if _, err := c.Flush(context.Background()); err != nil {
		t.Fatalf("Flush: %v", err)
	}
	raw, _ := fc.request(fc.count() - 1).Body["events"].([]any)
	out := make([]map[string]any, 0, len(raw))
	for _, e := range raw {
		out = append(out, e.(map[string]any))
	}
	return out
}

func TestGroupAndUserProperties(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc)
	ctx := context.Background()

	ev, err := c.Group(ctx, "acme-team", map[string]any{"plan": "team", "email": "x@y.co", "group_id": "baska"}, Identity{UserID: "u1"})
	if err != nil || ev == nil {
		t.Fatalf("Group: %v %v", ev, err)
	}
	for _, bad := range []string{"", "   ", strings.Repeat("a", 129), "ali@example.com", "a\tb"} {
		if ev, err := c.Group(ctx, bad, nil, Identity{}); ev != nil || err != nil {
			t.Fatalf("geçersiz grup %q olay üretmemeliydi: %v %v", bad, ev, err)
		}
	}
	if ev, _ := c.Group(ctx, strings.Repeat("g", 128), nil, Identity{}); ev == nil {
		t.Fatal("128 karakterlik grup kabul edilmeliydi")
	}
	if ev, err := c.SetUserProperties(ctx, map[string]any{"email": "a@b.co", "verified": true}, Identity{}); ev != nil || err != nil {
		t.Fatalf("geçerli özelliği olmayan çağrı olay üretmemeliydi: %v %v", ev, err)
	}
	if ev, err := c.SetUserProperties(ctx, map[string]any{"plan": "pro", "tier": 2, "phone": "555"}, Identity{AnonymousID: "anon_1"}); ev == nil || err != nil {
		t.Fatalf("SetUserProperties: %v %v", ev, err)
	}

	events := flushedEvents(t, c, fc)
	if len(events) != 3 {
		t.Fatalf("3 olay bekleniyordu, %d", len(events))
	}
	if events[0]["event_name"] != GroupEventName || events[0]["user_id"] != "u1" {
		t.Fatalf("grup olayı: %v", events[0])
	}
	if !reflect.DeepEqual(events[0]["properties"], map[string]any{"plan": "team", "group_id": "acme-team"}) {
		t.Fatalf("grup özellikleri: %v", events[0]["properties"])
	}
	if events[2]["event_name"] != UserPropertiesEventName || events[2]["anonymous_id"] != "anon_1" {
		t.Fatalf("kullanıcı özelliği olayı: %v", events[2])
	}
	if !reflect.DeepEqual(events[2]["properties"], map[string]any{"plan": "pro", "tier": float64(2)}) {
		t.Fatalf("kullanıcı özellikleri: %v", events[2]["properties"])
	}
}

func TestGlobalProperties(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc)
	ctx := context.Background()

	c.SetGlobalProperties(map[string]any{"app_release": "e2e", "plan": "free", "email": "a@b.co"})
	mustTrack := func(name string, props map[string]any) {
		t.Helper()
		if _, err := c.Track(ctx, Event{Name: name, Properties: props}); err != nil {
			t.Fatalf("Track %s: %v", name, err)
		}
	}
	mustTrack("page_view", map[string]any{"plan": "pro"})
	mustTrack("checkout", nil)
	_, _ = c.SetUserProperties(ctx, map[string]any{"tier": 1}, Identity{})
	_, _ = c.Group(ctx, "acme", nil, Identity{})
	c.SetGlobalProperties(map[string]any{"plan": nil})
	mustTrack("after_remove", nil)
	c.ClearGlobalProperties()
	mustTrack("after_clear", nil)

	events := flushedEvents(t, c, fc)
	wants := []map[string]any{
		{"plan": "pro", "app_release": "e2e"},
		{"app_release": "e2e", "plan": "free"},
		{"tier": float64(1)}, // fr_ sistem olayına global eklenmez
		{"group_id": "acme"},
		{"app_release": "e2e"},
		nil,
	}
	for i, want := range wants {
		got, _ := events[i]["properties"].(map[string]any)
		if want == nil {
			if _, present := events[i]["properties"]; present {
				t.Fatalf("olay %d özellik taşımamalıydı: %v", i, got)
			}
			continue
		}
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("olay %d: %v, beklenen %v", i, got, want)
		}
	}
}

func TestGlobalPropertiesLimitAndConcurrency(t *testing.T) {
	fc := newFakeCollector(t)
	c := newTestClient(t, fc, WithQueueLimit(10_000))
	first, second := map[string]any{}, map[string]any{}
	for i := 0; i < 40; i++ {
		first[fmt.Sprintf("g%02d", i)] = i
		second[fmt.Sprintf("h%02d", i)] = i
	}
	c.SetGlobalProperties(first)
	c.SetGlobalProperties(second)
	c.SetGlobalProperties(map[string]any{"g00": "yeni"})

	// Eşzamanlı yazma ve Track yarış dedektörüyle güvenli olmalı.
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(2)
		go func(i int) {
			defer wg.Done()
			c.SetGlobalProperties(map[string]any{"g01": i})
		}(i)
		go func() {
			defer wg.Done()
			_, _ = c.Track(context.Background(), Event{Name: "page_view"})
		}()
	}
	wg.Wait()
	c.ClearGlobalProperties()
	c.SetGlobalProperties(first)
	c.SetGlobalProperties(second)
	c.SetGlobalProperties(map[string]any{"g00": "yeni"})
	if _, err := c.Track(context.Background(), Event{Name: "page_view"}); err != nil {
		t.Fatal(err)
	}
	events := flushedEvents(t, c, fc)
	props := events[len(events)-1]["properties"].(map[string]any)
	if len(props) != MaxProfileProperties || props["g00"] != "yeni" {
		t.Fatalf("global sınır: %d anahtar, g00=%v", len(props), props["g00"])
	}
	if _, ok := props["h09"]; !ok {
		t.Fatal("h09 eklenmeliydi")
	}
	if _, ok := props["h10"]; ok {
		t.Fatal("h10 sınırı aşıyor, eklenmemeliydi")
	}
}
