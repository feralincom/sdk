<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# MCP stdio köprüsü: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `packages/mcp-server/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | TypeScript |
| Paket | `@feralin/mcp-server` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | REGISTRY_VERIFIED |
| Kaynak dizin | `packages/mcp-server` |
| Registry | npm: **PUBLISHED** (sonraki adım: her paket için npm trusted publishing (OIDC); npm 2FA'yı atlayan anahtarla doğrudan yayını Ocak 2027'de kapatıyor) |
| Derleme | `pnpm --filter @feralin/mcp-server build` |
| Test | `pnpm --filter @feralin/mcp-server test` |

## Kurulum

```bash
npm install --global @feralin/mcp-server
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
| registry | PASS | npm'de yayımlandı: @feralin/mcp-server@0.1.0 (17 Kasım 2026, git b1a7d127, org @feralin; ilk yayın site sahibinin tek onayıyla, docs/sdk/npm-yayin-adimlari.md B yolu; RELEASE_CANDIDATE dört göz koşulu bu yayında aranmadı). Registry'den geri okuma: latest 0.1.0, dist.integrity sha512-xdLBSOsMvw0S… yerel kuru koşu paketinin özetiyle birebir aynı, sahip org @feralin. npm ilk yayında 2 dosyalık 0.0.0-stage yer tutucu sürümünü de oluşturdu; Feralin yayını değildir. |
| clean_install | PASS | npm pack çıktısı boş dizine kuruldu, kurulu bin stdio ile çalıştı, 0 bağımlılık. Registry'den temiz kurulum: FERALIN_E2E_FROM_REGISTRY=1 node packages/mcp-server/scripts/e2e-real-mcp.mjs (17 Kasım 2026): @feralin/mcp-server@0.1.0 npmjs.org'dan boş dizine kuruldu (resolved https://registry.npmjs.org/@feralin/mcp-server/-/mcp-server-0.1.0.tgz, özet registry'deki dist.integrity ile aynı, kurulan tek paket), kurulu bin gerçek services/mcp + saas-api + PostgreSQL ile initialize, tools/list (22 araç), tools/call list_workspaces ve yanlış anahtarda HTTP 401 verdi; anahtar çıktıya sızmadı. |
| event_receipt | NOT_APPLICABLE | Olay göndermez; gerçek services/mcp + saas-api + PostgreSQL üzerinden initialize, tools/list, tools/call doğrulandı. |
| documentation | PASS | docs/sdk/mcp-server.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
