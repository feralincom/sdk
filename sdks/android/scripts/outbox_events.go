//go:build ignore

// outbox_events, verilen kiracının collect_outbox satırlarındaki ham olayları satır başına bir JSON olarak yazar (e2e-exit-info.mjs okur).
// Yalnız test veritabanı içindir; olay gövdesi toplayıcının temizlediği hâlidir.
//
//	cd services/collect && DATABASE_URL=... go run ../../sdks/android/scripts/outbox_events.go <tenant_id>
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"time"

	"github.com/jackc/pgx/v5"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "HATA:", err)
		os.Exit(1)
	}
}

func run() error {
	if len(os.Args) != 2 || os.Args[1] == "" {
		return fmt.Errorf("kullanım: outbox_events.go <tenant_id>")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return fmt.Errorf("veritabanı bağlantısı: %w", err)
	}
	defer conn.Close(ctx)
	rows, err := conn.Query(ctx, `SELECT payload::text FROM collect_outbox WHERE tenant_id = $1 ORDER BY id`, os.Args[1])
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var raw string
		if err := rows.Scan(&raw); err != nil {
			return err
		}
		var payload struct {
			Events []struct {
				Event json.RawMessage `json:"event"`
			} `json:"events"`
		}
		if err := json.Unmarshal([]byte(raw), &payload); err != nil {
			return err
		}
		for _, item := range payload.Events {
			fmt.Println(string(item.Event))
		}
	}
	return rows.Err()
}
