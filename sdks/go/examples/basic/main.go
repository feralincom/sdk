// Örnek: yerel collect servisine (services/collect, varsayılan :8081) tek bir sunucu olayı gönderir.
//
// Çalıştırma (collect açık ve anahtar COLLECT_PROJECT_KEYS içinde tanımlıyken):
//
//	FERALIN_PROJECT_KEY=pk_live_dev0000000000000000000000000001 \
//	FERALIN_COLLECT_URL=http://127.0.0.1:8081 go run ./examples/basic
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"os"
	"time"

	feralin "github.com/feralincom/sdk/sdks/go"
)

func main() {
	projectKey := os.Getenv("FERALIN_PROJECT_KEY")
	collectURL := os.Getenv("FERALIN_COLLECT_URL")
	if collectURL == "" {
		collectURL = "http://127.0.0.1:8081"
	}
	if projectKey == "" {
		fmt.Fprintln(os.Stderr, "FERALIN_PROJECT_KEY ortam değişkeni gerekli (pk_ ile başlayan proje anahtarı)")
		os.Exit(2)
	}

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	client, err := feralin.NewClient(projectKey, collectURL,
		feralin.WithConsent(feralin.Consent{Analytics: true}),
		feralin.WithFlushInterval(2*time.Second),
		feralin.WithLogger(logger),
	)
	if err != nil {
		fmt.Fprintln(os.Stderr, "istemci oluşturulamadı:", err)
		os.Exit(1)
	}

	// Sunucu tarafı sipariş olayı; user_id müşteri uygulamasının kendi kimliğidir, PII değildir.
	ev, err := client.Track(context.Background(), feralin.Event{
		Name:   "order_completed",
		UserID: "user_42",
		Properties: map[string]any{
			"order_id": "ord_1001",
			"amount":   249.90,
			"currency": "TRY",
			"items":    3,
		},
		Context: &feralin.Context{Locale: "tr-TR", Timezone: "Europe/Istanbul"},
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "olay üretilemedi:", err)
		os.Exit(1)
	}
	fmt.Println("kuyruğa alındı:", ev.EventID, ev.EventName, ev.OccurredAt)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	res, err := client.Flush(ctx)
	switch {
	case err == nil:
		fmt.Printf("gönderildi: batch_id=%s accepted=%d rejected=%d status=%d\n", res.BatchID, res.Accepted, res.Rejected, res.Status)
	case errors.Is(err, feralin.ErrTemporary):
		fmt.Printf("geçici hata, kuyrukta %d olay tutuluyor: %v\n", res.Retained, err)
	case errors.Is(err, feralin.ErrRejected):
		fmt.Printf("toplayıcı reddetti (status=%d): %v\n", res.Status, err)
	default:
		fmt.Println("gönderim hatası:", err)
	}

	if err := client.Close(); err != nil {
		fmt.Fprintln(os.Stderr, "kapanışta gönderilemeyen olay var:", err)
		os.Exit(1)
	}
}
