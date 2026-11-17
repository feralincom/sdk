// Yalnız ESM üretir: Angular paketleri ESM'dir. Dekoratör olmadığından ngc gerekmez.
import { spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const tsc = createRequire(join(root, "package.json")).resolve("typescript/bin/tsc");
rmSync(join(root, "dist"), { recursive: true, force: true });
const result = spawnSync(process.execPath, [tsc, "-p", "tsconfig.json"], { cwd: root, stdio: "inherit" });
if (result.status !== 0) process.exit(result.status ?? 1);
