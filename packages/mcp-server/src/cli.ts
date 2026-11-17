#!/usr/bin/env node
// Giriş noktası. Ortam: FERALIN_API_KEY (zorunlu), FERALIN_MCP_URL (varsayılan https://feralin.com/mcp).
import { BRIDGE_VERSION, ConfigError, StdioBridge, resolveConfig } from "./bridge.js";

const argv = process.argv.slice(2);

if (argv.includes("--version")) {
  process.stderr.write(`${BRIDGE_VERSION}\n`);
  process.exit(0);
}
if (argv.includes("--help")) {
  process.stderr.write(
    [
      "feralin-mcp-server: Feralin MCP stdio köprüsü",
      "",
      "Ortam değişkenleri:",
      "  FERALIN_API_KEY  Feralin API anahtarı (zorunlu; komut satırından verilemez)",
      "  FERALIN_MCP_URL  MCP adresi (varsayılan https://feralin.com/mcp; http yalnız yerel adreste)",
      "",
    ].join("\n"),
  );
  process.exit(0);
}

try {
  const { url, token } = resolveConfig(process.env, argv);
  // Alt süreçlere ve hata dökümlerine geçmesin.
  delete process.env.FERALIN_API_KEY;
  const bridge = new StdioBridge({
    url,
    token,
    input: process.stdin,
    output: process.stdout,
    log: (message) => process.stderr.write(`[feralin-mcp-server] ${message}\n`),
  });
  await bridge.run();
} catch (err) {
  const message = err instanceof ConfigError ? err.message : `başlatılamadı: ${err instanceof Error ? err.name : "unknown"}`;
  process.stderr.write(`[feralin-mcp-server] ${message}\n`);
  process.exit(1);
}
