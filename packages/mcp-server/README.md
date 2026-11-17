# @feralin/mcp-server

Yalnız stdio destekleyen MCP istemcilerini HTTPS üzerinden Feralin MCP sunucusuna bağlayan köprü. MCP içeriğini yorumlamaz, JSON-RPC mesajlarını taşır: araç kararları, yetki ve kiracı sınırı sunucudadır. Veritabanı, kalıcı durum ve sır barındırmaz. Çalışma zamanı bağımlılığı yoktur.

İstemciniz Streamable HTTP destekliyorsa bu pakete gerek yoktur; doğrudan OAuth ile bağlanın (`services/mcp/README.md`).

## Durum

| Konu | Durum |
|---|---|
| Kod, birim testleri | Geçiyor |
| `npm pack` temiz kurulum + gerçek `services/mcp` + saas-api + PostgreSQL | `scripts/e2e-real-mcp.mjs` ile doğrulandı (`initialize`, `tools/list`, `tools/call`, yanlış anahtar) |
| npm yayını | npm'de yayımlandı: `@feralin/mcp-server@0.1.0` (17 Kasım 2026, `@feralin` organizasyonu); sürüm ve özet registry'den geri okundu |

## Kurulum

Köprü komutu (`feralin-mcp-server`) genel kurulumla PATH'e eklenir:

```bash
npm install --global @feralin/mcp-server
```

## Kullanım

MCP istemcisinin yapılandırmasına köprü komutu eklenir.

| Değişken | Açıklama |
|---|---|
| `FERALIN_API_KEY` | Feralin API anahtarı (`fak_…`). Zorunlu. Komut satırından verilemez, `pk_` proje anahtarı reddedilir |
| `FERALIN_MCP_URL` | Varsayılan `https://feralin.com/mcp`. `http` yalnız `127.0.0.1` ve `localhost` için kabul edilir |

```json
{
  "mcpServers": {
    "feralin": {
      "command": "feralin-mcp-server",
      "env": { "FERALIN_API_KEY": "<panelden üretilen anahtar>" }
    }
  }
}
```

Anahtarı depoya işlenen yapılandırma dosyasına yazmayın.

## Davranış

- Mesajlar satır başına bir JSON-RPC nesnesidir. stdout yalnız protokol içindir; tüm günlük stderr'e yazılır, anahtar ve mesaj içeriği taşımaz.
- `initialize` yanıtındaki `Mcp-Session-Id` ve protokol sürümü sonraki isteklere eklenir. `initialize` bitmeden sonraki istekler gönderilmez.
- stdin kapanınca bekleyen istekler biter, oturum `DELETE` ile kapatılır.
- Sunucu reddi ve ağ hatası JSON-RPC hatasına çevrilir (`-32000`, `data.http_status`). Süreç düşmez. Oturum süresi dolarsa (404) eski kimlik atılır, istemci yeniden `initialize` etmelidir.
- `text/event-stream` yanıtı satırlara çevrilir.

## Sınırlar

Sunucudan başlatılan bildirimleri taşıyan `GET /mcp` akışı açılmaz; yalnız istek yanıtı içindeki mesajlar iletilir. Feralin MCP bugün salt okunurdur ve böyle bir akış kullanmaz. OAuth köprüde yoktur, API anahtarı gerekir.

## Geliştirme

```bash
pnpm --filter @feralin/mcp-server build
pnpm --filter @feralin/mcp-server test
MCP_E2E_DATABASE_URL='postgres://kullanici:parola@127.0.0.1:5432/test_db?sslmode=disable' pnpm --filter @feralin/mcp-server test:e2e
```
