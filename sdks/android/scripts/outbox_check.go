//go:build ignore

// outbox_check SDK uçtan uca testlerinin bıraktığı denetim satırlarını collect_outbox üzerinde doğrular.
// Veritabanı paylaşımlı olabilir ve başka bir worker satırları yayımlamış olabilir; bu yüzden sayaç değil,
// testin kendi batch_id veya event_id değeri aranır (published_at durumundan bağımsız).
//
//	cd services/collect && DATABASE_URL=... go run ../../sdks/android/scripts/outbox_check.go <dosya> [dosya...]
//
// Satır biçimi:
//
//	frclick <batch_id>    satır var; en az bir olay fr_click ve consent.advertising=true taşır
//	nofrclick <batch_id>  satır var; hiçbir olay fr_click taşımaz
//	once <event_id>       olay tam bir outbox satırında
//	absent <event_id>     olay hiçbir outbox satırında yok
//	twice <event_id>      olay tam iki outbox satırında (farklı Idempotency-Key ile yeniden gönderim; ClickHouse'ta yine bir kez sayılır)
//	published <event_id>  olayı taşıyan bütün satırlar worker tarafından yayımlanmış (published_at dolu)
//	nofrclickevent <event_id>        olay outbox'ta ve fr_click taşımıyor
//	platform <platform>:<event_id>   olay outbox'ta ve platform alanı beklenen değerde
//	installcodetable -                             saas-api şeması var (install_verification_codes); yoksa hata
//	seedinstallcode <kiracı>:<proje>:<kod>         kiracı, proje ve bekleyen kod satırı yazılır (yalnız özet saklanır)
//	installcodematched <kiracı>:<proje>:<kod>:<olay adı>:<platform>:<sdk adı>  toplayıcı kodu bu olayla eşleştirmiş
package main

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
)

type event struct {
	EventID    string         `json:"event_id"`
	EventName  string         `json:"event_name"`
	Platform   string         `json:"platform"`
	Properties map[string]any `json:"properties"`
	Consent    map[string]any `json:"consent"`
	Context    map[string]any `json:"context"`
}

// Outbox satırı collect'in zarfıdır: her kayıt ham olayı "event" altında, sunucu alanlarıyla birlikte taşır.
type payload struct {
	Events []struct {
		Event event `json:"event"`
	} `json:"events"`
}

// Kodun özeti: toplayıcı (`services/collect/internal/worker/installcode.go`) ve saas-api ile aynı biçim, gizli tuz yok.
func installCodeHash(canonical string) string {
	sum := sha256.Sum256([]byte(canonical))
	return hex.EncodeToString(sum[:])
}

func deref(value *string) string {
	if value == nil {
		return "<yok>"
	}
	return *value
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "HATA:", err)
		os.Exit(1)
	}
}

func run(files []string) error {
	if len(files) == 0 {
		return fmt.Errorf("en az bir denetim dosyası gerekli")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	conn, err := pgx.Connect(ctx, os.Getenv("DATABASE_URL"))
	if err != nil {
		return fmt.Errorf("veritabanı bağlantısı: %w", err)
	}
	defer conn.Close(ctx)

	checked := 0
	for _, path := range files {
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		defer file.Close()
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			kind, id, ok := strings.Cut(strings.TrimSpace(scanner.Text()), " ")
			if !ok {
				continue
			}
			if err := check(ctx, conn, kind, id); err != nil {
				return err
			}
			checked++
		}
	}
	if checked == 0 {
		return fmt.Errorf("denetlenecek satır yok; testler koşmamış olabilir")
	}
	fmt.Printf("outbox denetimi: %d satır doğrulandı\n", checked)
	return nil
}

func check(ctx context.Context, conn *pgx.Conn, kind, id string) error {
	switch kind {
	case "frclick", "nofrclick":
		var raw []byte
		var published bool
		err := conn.QueryRow(ctx, `SELECT payload::text, published_at IS NOT NULL FROM collect_outbox WHERE batch_id = $1`, id).Scan(&raw, &published)
		if err != nil {
			return fmt.Errorf("batch %s outbox'ta bulunamadı: %w", id, err)
		}
		var p payload
		if err := json.Unmarshal(raw, &p); err != nil {
			return fmt.Errorf("payload çözülemedi: %w", err)
		}
		withClick := 0
		for _, record := range p.Events {
			e := record.Event
			props, _ := json.Marshal(e.Properties)
			contextJSON, _ := json.Marshal(e.Context)
			consent, _ := json.Marshal(e.Consent)
			fmt.Printf("  %s %s platform=%s yayimlandi=%v consent=%s props=%s context=%s\n", e.EventID, e.EventName, e.Platform, published, consent, props, contextJSON)
			if _, has := e.Properties["fr_click"]; has {
				withClick++
				if e.Consent["advertising"] != true {
					return fmt.Errorf("batch %s: fr_click reklam izni olmadan gitmiş", id)
				}
			}
			if strings.Contains(string(props), "GIZLI") || strings.Contains(string(contextJSON), "GIZLI") {
				return fmt.Errorf("batch %s: temizlenmemiş sorgu değeri", id)
			}
		}
		if kind == "frclick" && withClick == 0 {
			return fmt.Errorf("batch %s: fr_click bekleniyordu", id)
		}
		if kind == "nofrclick" && withClick != 0 {
			return fmt.Errorf("batch %s: fr_click olmamalıydı", id)
		}
		fmt.Printf("%s %s OK\n", kind, id)
	case "once", "absent", "twice":
		var count int
		err := conn.QueryRow(ctx, `SELECT count(*) FROM collect_outbox WHERE payload::text LIKE '%' || $1 || '%'`, id).Scan(&count)
		if err != nil {
			return err
		}
		want := map[string]int{"once": 1, "absent": 0, "twice": 2}[kind]
		if count != want {
			return fmt.Errorf("%s %s: %d satır bulundu, %d bekleniyordu", kind, id, count, want)
		}
		fmt.Printf("%s %s OK\n", kind, id)
	case "published":
		// Olayı taşıyan bütün satırlar worker tarafından ClickHouse'a yayımlanmış olmalı (run.mjs ClickHouse aşaması bekler).
		var total, published int
		err := conn.QueryRow(ctx, `SELECT count(*), count(published_at) FROM collect_outbox WHERE payload::text LIKE '%' || $1 || '%'`, id).Scan(&total, &published)
		if err != nil {
			return err
		}
		if total == 0 || published != total {
			return fmt.Errorf("published %s: %d satırdan %d yayımlandı", id, total, published)
		}
		fmt.Printf("%s %s OK (%d satır)\n", kind, id, total)
	case "nofrclickevent":
		e, err := findEvent(ctx, conn, id)
		if err != nil {
			return err
		}
		if _, has := e.Properties["fr_click"]; has {
			return fmt.Errorf("olay %s: fr_click reklam izni olmadan gitmiş", id)
		}
		fmt.Printf("%s %s OK (consent=%v props=%v)\n", kind, id, e.Consent, e.Properties)
	case "platform":
		want, eventID, ok := strings.Cut(id, ":")
		if !ok {
			return fmt.Errorf("platform denetimi <platform>:<event_id> olmalı: %s", id)
		}
		e, err := findEvent(ctx, conn, eventID)
		if err != nil {
			return err
		}
		if e.Platform != want {
			return fmt.Errorf("olay %s: platform %s, beklenen %s", eventID, e.Platform, want)
		}
		fmt.Printf("%s %s OK\n", kind, id)
	case "installcodetable":
		var present bool
		if err := conn.QueryRow(ctx, `SELECT to_regclass('public.install_verification_codes') IS NOT NULL AND to_regclass('public.projects') IS NOT NULL`).Scan(&present); err != nil {
			return err
		}
		if !present {
			return fmt.Errorf("install_verification_codes tablosu yok: saas-api migrasyonlu veritabanı gerekir")
		}
		fmt.Println("installcodetable OK")
	case "seedinstallcode":
		parts := strings.Split(id, ":")
		if len(parts) != 3 {
			return fmt.Errorf("seedinstallcode <kiracı>:<proje>:<kod> olmalı: %s", id)
		}
		tenant, project, code := parts[0], parts[1], parts[2]
		if len(code) != 10 {
			return fmt.Errorf("kod kanonik biçimde (10 karakter) verilmeli")
		}
		if _, err := conn.Exec(ctx, `INSERT INTO organizations (id, name) VALUES ($1, 'SDK emülatör testi') ON CONFLICT (id) DO NOTHING`, tenant); err != nil {
			return fmt.Errorf("kiracı yazılamadı: %w", err)
		}
		if _, err := conn.Exec(ctx, `INSERT INTO projects (id, organization_id, name, platform) VALUES ($1, $2, 'SDK emülatör testi', 'android') ON CONFLICT (id) DO NOTHING`, project, tenant); err != nil {
			return fmt.Errorf("proje yazılamadı: %w", err)
		}
		// Önceki koşunun satırı kalmış olabilir: aynı projede yalnız bu koşunun kodu bekler (saas-api `issue` ile aynı kural).
		if _, err := conn.Exec(ctx, `DELETE FROM install_verification_codes WHERE tenant_id = $1 AND project_id = $2`, tenant, project); err != nil {
			return err
		}
		if _, err := conn.Exec(ctx, `INSERT INTO install_verification_codes (tenant_id, project_id, code_hash, code_prefix, expires_at) VALUES ($1, $2, $3, $4, now() + interval '30 minutes')`,
			tenant, project, installCodeHash(code), code[:4]); err != nil {
			return fmt.Errorf("kod yazılamadı: %w", err)
		}
		fmt.Printf("%s %s:%s OK (önek %s, 30 dk)\n", kind, tenant, project, code[:4])
	case "installcodematched":
		parts := strings.Split(id, ":")
		if len(parts) != 6 {
			return fmt.Errorf("installcodematched <kiracı>:<proje>:<kod>:<olay adı>:<platform>:<sdk adı> olmalı: %s", id)
		}
		var eventID, eventName, platform, sdkName, sdkVersion *string
		var matchedAt *time.Time
		err := conn.QueryRow(ctx, `SELECT matched_event_id, matched_event_name, matched_platform, matched_sdk_name, matched_sdk_version, matched_at
			   FROM install_verification_codes WHERE tenant_id = $1 AND project_id = $2 AND code_hash = $3`, parts[0], parts[1], installCodeHash(parts[2])).
			Scan(&eventID, &eventName, &platform, &sdkName, &sdkVersion, &matchedAt)
		if err != nil {
			return fmt.Errorf("kod satırı okunamadı: %w", err)
		}
		if eventID == nil || matchedAt == nil {
			return fmt.Errorf("installcodematched: kod eşleşmemiş (toplayıcı kodu taşıyan olayı görmedi)")
		}
		if eventName == nil || *eventName != parts[3] || platform == nil || *platform != parts[4] || sdkName == nil || *sdkName != parts[5] {
			return fmt.Errorf("installcodematched: beklenen %s/%s/%s, gelen %v/%v/%v", parts[3], parts[4], parts[5], deref(eventName), deref(platform), deref(sdkName))
		}
		fmt.Printf("%s OK olay=%s ad=%s platform=%s sdk=%s@%s eşleşme=%s\n", kind, *eventID, *eventName, *platform, *sdkName, deref(sdkVersion), matchedAt.UTC().Format(time.RFC3339))
	default:
		return fmt.Errorf("bilinmeyen denetim: %s", kind)
	}
	return nil
}

// findEvent olayı taşıyan outbox satırından ham olayı döndürür.
func findEvent(ctx context.Context, conn *pgx.Conn, id string) (event, error) {
	var raw []byte
	err := conn.QueryRow(ctx, `SELECT payload::text FROM collect_outbox WHERE payload::text LIKE '%' || $1 || '%' LIMIT 1`, id).Scan(&raw)
	if err != nil {
		return event{}, fmt.Errorf("olay %s outbox'ta bulunamadı: %w", id, err)
	}
	var p payload
	if err := json.Unmarshal(raw, &p); err != nil {
		return event{}, fmt.Errorf("payload çözülemedi: %w", err)
	}
	for _, record := range p.Events {
		if record.Event.EventID == id {
			return record.Event, nil
		}
	}
	return event{}, fmt.Errorf("olay %s satırda çözülemedi", id)
}
