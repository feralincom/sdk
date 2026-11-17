// npm pack öncesi: JS derlenir ve Android çekirdeği paket içindeki yerel Maven deposuna konur. Maven Central yayını olmadığından
// (BLOCKED_EXTERNAL) temiz kurulum çekirdeği buradan alır. Hiçbir uzak registry'ye yükleme yapılmaz.
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const android = join(root, "../android");
const repo = join(root, "android/maven-repo");

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, stdio: "inherit" });
  if (result.status !== 0) {
    console.error(`HATA: ${command} ${args.join(" ")}`);
    process.exit(result.status ?? 1);
  }
}

// Paket pnpm çalışma alanı dışındadır (react-native eş bağımlılığı kilit dosyasını büyütmesin); tsc depo kökünden gelir.
const tsc = createRequire(join(root, "../../package.json")).resolve("typescript/bin/tsc");
run(process.execPath, [tsc, "-p", "tsconfig.json"], root);
rmSync(repo, { recursive: true, force: true });
const gradlew = process.platform === "win32" ? "cmd.exe" : "./gradlew";
// cmd.exe geçerli dizini aramayabilir (NoDefaultCurrentDirectoryInExePath); tam yol verilir.
const prefix = process.platform === "win32" ? ["/d", "/c", join(android, "gradlew.bat")] : [];
run(gradlew, [...prefix, ":feralin:publishReleasePublicationToLocalVendorRepository", `-PferalinVendorRepo=${repo}`, "--console=plain", "-q"], android);
console.log(`çekirdek yerel depoda: ${repo}`);
