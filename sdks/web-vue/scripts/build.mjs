// ESM ve CommonJS çıktısını yalnız tsc ile üretir; "use client" yönergesi paketleyici olmadan korunur.
import { spawnSync } from "node:child_process";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const tsc = createRequire(join(root, "package.json")).resolve("typescript/bin/tsc");

function compile(args) {
  const result = spawnSync(process.execPath, [tsc, ...args], { cwd: root, stdio: "inherit" });
  if (result.status !== 0) process.exit(result.status ?? 1);
}

rmSync(join(root, "dist"), { recursive: true, force: true });
compile(["-p", "tsconfig.json"]);
compile(["-p", "tsconfig.json", "--module", "CommonJS", "--moduleResolution", "Node10", "--ignoreDeprecations", "5.0", "--outDir", "dist/cjs"]);
mkdirSync(join(root, "dist/cjs"), { recursive: true });
// Paket "type": "module" olduğundan CommonJS klasörü kendi türünü bildirir.
writeFileSync(join(root, "dist/cjs/package.json"), JSON.stringify({ type: "commonjs" }) + "\n");
writeFileSync(join(root, "dist/esm/package.json"), JSON.stringify({ type: "module" }) + "\n");
