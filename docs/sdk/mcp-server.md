<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# MCP stdio köprüsü: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `packages/mcp-server/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/mcp-server` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `packages/mcp-server` |
| Registry | npm: **BLOCKED_EXTERNAL** (gereken: @feralin npm organizasyonu, 2FA, OIDC trusted publishing) |
| Derleme | `pnpm --filter @feralin/mcp-server build` |
| Test | `pnpm --filter @feralin/mcp-server test` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `npm` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
cd packages/mcp-server
npm pack
npm install --global ./feralin-mcp-server-0.1.0.tgz
```

## İlk kullanım

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

## Yetenekler

Bu SDK kendi yetenek satırını taşımaz; yetenekler bir üst katmanın (çekirdek paketin) yetenekleridir ve onun belgesinde yazılıdır.

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS |  |
| test | PASS |  |
| registry | BLOCKED_EXTERNAL | @feralin npm organizasyonu yok. |
| clean_install | PASS | npm pack çıktısı boş dizine kuruldu, kurulu bin stdio ile çalıştı, 0 bağımlılık. |
| event_receipt | NOT_APPLICABLE | Olay göndermez; gerçek services/mcp + saas-api + PostgreSQL üzerinden initialize, tools/list, tools/call doğrulandı. |
| documentation | PASS | docs/sdk/mcp-server.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
