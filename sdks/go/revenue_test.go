package feralin

import (
	"context"
	"errors"
	"testing"
)

// F5-E04-T01: trackRevenue `feralin_purchase` sözleşmesini üretir; verified düşer, ham makbuz olduğu gibi gider (özetini toplayıcı alır).
func TestTrackRevenueContract(t *testing.T) {
	fc := newFakeCollector(t, scripted{status: 202, body: `{"batch_id":"01TESTBATCH0000000000000000","accepted":1,"rejected":0}`})
	c, err := NewClient(testKey, fc.srv.URL, WithConsent(Consent{Analytics: true}), WithFlushInterval(0))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	ev, err := c.TrackRevenue(context.Background(), Revenue{
		TransactionID: "ord_1",
		AmountMinor:   4999,
		Currency:      "TRY",
		ProductID:     "pro",
		PurchaseType:  PurchaseTypeSubscriptionStart,
		Receipt:       &Receipt{Provider: "stripe", Token: "tok_1"},
		Properties:    map[string]any{"verified": true, "receipt_digest": "x", "plan": "pro"},
		UserID:        "user_42",
	})
	if err != nil || ev == nil {
		t.Fatalf("TrackRevenue: ev=%v err=%v", ev, err)
	}
	if ev.EventName != RevenueEventName || ev.UserID != "user_42" {
		t.Fatalf("olay adı ya da kimlik hatalı: %+v", ev)
	}
	props := ev.Properties
	if props["transaction_id"] != "ord_1" || props["amount_minor"] != int64(4999) || props["currency"] != "TRY" || props["quantity"] != 1 || props["purchase_type"] != PurchaseTypeSubscriptionStart || props["product_id"] != "pro" || props["plan"] != "pro" {
		t.Fatalf("sözleşme alanları hatalı: %+v", props)
	}
	if _, ok := props["verified"]; ok {
		t.Fatalf("verified istemciden gitmemeli: %+v", props)
	}
	if _, ok := props["receipt_digest"]; ok {
		t.Fatalf("receipt_digest istemciden gitmemeli: %+v", props)
	}
	receipt, _ := props["receipt"].(map[string]any)
	if receipt["provider"] != "stripe" || receipt["token"] != "tok_1" {
		t.Fatalf("makbuz hatalı: %+v", props["receipt"])
	}
	if _, err := c.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	wire := fc.request(0).Body["events"].([]any)[0].(map[string]any)
	assertWireEvent(t, wire)
	if _, ok := wire["verified"]; ok {
		t.Fatalf("tel üzerinde verified olmamalı: %v", wire)
	}
}

func TestTrackRevenueRejectsInvalidInput(t *testing.T) {
	fc := newFakeCollector(t)
	c, err := NewClient(testKey, fc.srv.URL, WithConsent(Consent{Analytics: true}), WithFlushInterval(0))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	cases := map[string]Revenue{
		"boş işlem":         {TransactionID: "", AmountMinor: 1, Currency: "TRY"},
		"eksi tutar":        {TransactionID: "t", AmountMinor: -1, Currency: "TRY"},
		"aralık dışı tutar": {TransactionID: "t", AmountMinor: MaxAmountMinor + 1, Currency: "TRY"},
		"küçük harf birim":  {TransactionID: "t", AmountMinor: 1, Currency: "try"},
		"eksi adet":         {TransactionID: "t", AmountMinor: 1, Currency: "TRY", Quantity: -1},
		"bilinmeyen tür":    {TransactionID: "t", AmountMinor: 1, Currency: "TRY", PurchaseType: "gift"},
		"bilinmeyen makbuz": {TransactionID: "t", AmountMinor: 1, Currency: "TRY", Receipt: &Receipt{Provider: "paypal", Token: "x"}},
		"boş belirteç":      {TransactionID: "t", AmountMinor: 1, Currency: "TRY", Receipt: &Receipt{Provider: "apple"}},
		"tutarlı iptal":     {TransactionID: "t", AmountMinor: 1, Currency: "TRY", PurchaseType: PurchaseTypeSubscriptionCancel},
	}
	for name, r := range cases {
		ev, err := c.TrackRevenue(context.Background(), r)
		if ev != nil || !errors.Is(err, ErrInvalidRevenue) {
			t.Fatalf("%s: ev=%v err=%v", name, ev, err)
		}
	}
	if c.Len() != 0 {
		t.Fatalf("geçersiz girdi kuyruğa girmemeli: %d", c.Len())
	}
}
