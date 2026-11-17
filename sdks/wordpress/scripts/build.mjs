#!/usr/bin/env node
// Eklentiyi dağıtılabilir hale getirir: Web SDK derlemesi ve PHP SDK kaynağı eklentinin içine kopyalanır, çıktı dist/ altındadır.
// PHP gerektirmez; eklentinin çalıştığını kanıtlamaz.
import { cpSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const repo = join(root, "../..");
const webBuild = join(repo, "packages/sdk-web/dist/feralin.iife.js");
if (!existsSync(webBuild)) {
  console.error("HATA: Web SDK derlemesi yok; önce pnpm --filter @feralin/web build");
  process.exit(1);
}
const out = join(root, "dist/feralin");
rmSync(join(root, "dist"), { recursive: true, force: true });
mkdirSync(out, { recursive: true });
cpSync(join(root, "feralin"), out, { recursive: true });
mkdirSync(join(out, "assets"), { recursive: true });
cpSync(webBuild, join(out, "assets/feralin.iife.js"));
cpSync(join(repo, "sdks/php/src"), join(out, "lib/feralin-php"), { recursive: true });
cpSync(join(repo, "sdks/php/README.md"), join(out, "lib/feralin-php/README.md"));
console.log(`eklenti hazır: ${out}`);
