#!/usr/bin/env node
// Android emülatöründe ANR → sonraki açılışta `fr_error` (origin: anr) → gerçek services/collect PostgreSQL outbox → aynı derlemenin gerçek
// R8 mapping.txt dosyasıyla saas-api çözücüsü (r8-mapping.ts) üzerinden özgün sınıf/yöntem/satır. Örnek uygulama küçültülmüş (R8) yayın
// derlemesidir; yalnız bu yerel test için Android Gradle'ın hata ayıklama anahtarıyla imzalanır. Başka emülatöre dokunulmaz: kendi portunda
// (varsayılan 5564) salt okunur açılır ve sonda yalnız o kapatılır.
//   DATABASE_URL='postgres://...' node sdks/android/scripts/e2e-exit-info.mjs
import { spawn, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const androidRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = join(androidRoot, "..", "..");
const database = process.env.DATABASE_URL;
if (!database) {
  console.error("DATABASE_URL zorunlu (yalnız test veritabanı)");
  process.exit(2);
}
const isWindows = process.platform === "win32";
const androidHome = process.env.ANDROID_HOME ?? join(process.env.LOCALAPPDATA ?? "", "Android", "Sdk");
const adbPath = join(androidHome, "platform-tools", isWindows ? "adb.exe" : "adb");
const emulatorPath = join(androidHome, "emulator", isWindows ? "emulator.exe" : "emulator");
const emulatorPort = process.env.FERALIN_ANDROID_EMULATOR_PORT ?? "5564";
const serial = `emulator-${emulatorPort}`;
const avd = process.env.FERALIN_ANDROID_AVD ?? "Test";
const collectPort = process.env.FERALIN_ANDROID_COLLECT_PORT ?? "4764";
const projectKey = "pk_test_feralin_exit_info";
const pkg = "com.feralin.sample";
const work = mkdtempSync(join(tmpdir(), "fr-exit-"));
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const adb = (...args) => spawnSync(adbPath, ["-s", serial, ...args], { encoding: "utf8" });

function run(command, args, options = {}) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const shellTool = isWindows && command.endsWith(".bat");
  const [file, argv] = shellTool ? ["cmd.exe", ["/d", "/c", command, ...args]] : [command, args];
  const result = spawnSync(file, argv, { stdio: "inherit", ...options });
  if (result.status !== 0) throw new Error(`komut başarısız (${result.status ?? result.error}): ${command} ${args.join(" ")}`);
}

function expect(condition, message) {
  if (!condition) throw new Error(`KALDI: ${message}`);
  console.log(`  OK ${message}`);
}

async function startCollect() {
  const binary = join(work, isWindows ? "collect.exe" : "collect");
  run("go", ["build", "-o", binary, "./cmd/collect"], { cwd: join(repoRoot, "services/collect") });
  const child = spawn(binary, [], {
    env: { ...process.env, COLLECT_ADDR: `127.0.0.1:${collectPort}`, DATABASE_URL: database, COLLECT_AUTO_MIGRATE: "true", COLLECT_PROJECT_KEYS: `${projectKey}=tenant_sdk_exit:proj_sdk_exit` },
    stdio: "ignore",
  });
  for (let i = 0; i < 120; i++) {
    await sleep(500);
    try {
      const health = await (await fetch(`http://127.0.0.1:${collectPort}/v1/health`)).text();
      if (health.includes('"outbox":"postgres"')) return child;
    } catch {
      // henüz dinlemiyor
    }
  }
  throw new Error("collect açılmadı");
}

async function bootEmulator() {
  const child = spawn(emulatorPath, ["-avd", avd, "-port", emulatorPort, "-no-window", "-read-only", "-no-audio", "-no-boot-anim", "-no-snapshot"], { stdio: "ignore" });
  for (let i = 0; i < 300; i++) {
    await sleep(2000);
    if (child.exitCode !== null) throw new Error(`emülatör çıktı (${child.exitCode})`);
    if (adb("shell", "getprop", "sys.boot_completed").stdout?.trim() === "1") {
      console.log(`emülatör hazır: ${serial} (${avd}), API ${adb("shell", "getprop", "ro.build.version.sdk").stdout.trim()}`);
      return child;
    }
  }
  throw new Error("emülatör 10 dakikada açılmadı");
}

/** Ekrandaki düğümü metniyle bulur (uiautomator dökümü); bulunamazsa null. */
function findNode(pattern) {
  adb("shell", "uiautomator", "dump", "/sdcard/fr-ui.xml");
  const xml = adb("exec-out", "cat", "/sdcard/fr-ui.xml").stdout ?? "";
  for (const match of xml.matchAll(/<node [^>]*?text="([^"]*)"[^>]*?bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"/g)) {
    if (pattern.test(match[1])) return { text: match[1], x: Math.round((Number(match[2]) + Number(match[4])) / 2), y: Math.round((Number(match[3]) + Number(match[5])) / 2) };
  }
  return null;
}

async function tap(pattern, timeoutMs = 20_000) {
  const until = Date.now() + timeoutMs;
  while (Date.now() < until) {
    const node = findNode(pattern);
    if (node) {
      adb("shell", "input", "tap", String(node.x), String(node.y));
      return node.text;
    }
    await sleep(1000);
  }
  throw new Error(`ekranda bulunamadı: ${pattern}`);
}

function pid() {
  return adb("shell", "pidof", pkg).stdout.trim();
}

/** Bu testin kiracısının outbox olayları (`scripts/outbox_events.go`, services/collect modülündeki pgx ile). */
function outboxEvents() {
  const result = spawnSync("go", ["run", join(androidRoot, "scripts/outbox_events.go"), "tenant_sdk_exit"], { cwd: join(repoRoot, "services/collect"), encoding: "utf8", env: { ...process.env, DATABASE_URL: database } });
  if (result.status !== 0) throw new Error(`outbox okunamadı: ${result.stderr}`);
  return result.stdout.split("\n").filter((line) => line.trim() !== "").map((line) => JSON.parse(line));
}

let collect;
let emulator;
let exitCode = 0;
const started = new Date();
try {
  const gradlew = join(androidRoot, isWindows ? "gradlew.bat" : "gradlew");
  run(gradlew, [":sample:assembleRelease", "-PfeSampleDebugSign=true", `-PfeSampleCollectUrl=http://10.0.2.2:${collectPort}`, `-PfeSampleKey=${projectKey}`, "--console=plain", "-q"], { cwd: androidRoot, env: { ...process.env, ANDROID_HOME: androidHome } });
  const apk = join(androidRoot, "sample/build/outputs/apk/release/sample-release.apk");
  const mappingPath = join(androidRoot, "sample/build/outputs/mapping/release/mapping.txt");
  expect(existsSync(apk) && existsSync(mappingPath), "R8 yayın derlemesi ve mapping.txt üretildi");
  collect = await startCollect();
  emulator = await bootEmulator();
  adb("uninstall", pkg);
  const installed = adb("install", "-r", apk);
  if (installed.status !== 0) throw new Error(`kurulum başarısız: ${installed.stdout}${installed.stderr}`);

  // 1. açılış: özellik ilk kez açılır (geçmiş raporlanmaz), analitik izni verilir.
  adb("shell", "am", "start", "-W", "-n", `${pkg}/.MainActivity`);
  await tap(/^(Allow analytics only|Yalnız analitiğe izin ver)$/i);
  await sleep(1500);

  // ANR: uygulama arka plandayken ön plan yayını alıcının ana iş parçacığını kilitler; 10 saniyelik yayın süresi dolunca sistem süreci ANR
  // nedeniyle iletişim kutusu olmadan sonlandırır (ön plandaki ANR iletişim kutusu uiautomator dökümünde görünmediği için bu yol seçildi).
  adb("shell", "input", "keyevent", "KEYCODE_HOME");
  await sleep(2000);
  const before = pid();
  expect(before !== "", "uygulama süreci arka planda yaşıyor");
  const broadcast = spawn(adbPath, ["-s", serial, "shell", "am", "broadcast", "-f", "0x10000000", "-n", `${pkg}/.AnrProbeReceiver`], { stdio: "ignore" });
  for (let i = 0; i < 90 && pid() === before; i++) await sleep(500);
  broadcast.kill();
  expect(pid() !== before, "ANR sonrası süreç sonlandı");
  const exits = adb("shell", "dumpsys", "activity", "exit-info", pkg).stdout;
  expect(/reason=6 \(ANR\)/.test(exits), "sistem çıkış kaydı REASON_ANR (6)");

  // 2. açılış: SDK önceki açılışın kaydını okur, olayı üretir ve ön planda gönderir.
  adb("shell", "am", "start", "-W", "-n", `${pkg}/.MainActivity`);
  let anr;
  for (let i = 0; i < 40 && !anr; i++) {
    await sleep(1500);
    anr = outboxEvents().find((event) => event.event_name === "fr_error" && event.properties?.origin === "anr");
  }
  expect(anr, "fr_error (origin: anr) collect_outbox'ta");
  const props = anr.properties;
  console.log(`  olay: ${JSON.stringify(props)}`);
  expect(props.error_type === "ApplicationNotResponding" && props.fatal === true && props.handled === false, "tür, ölümcül ve yakalanmamış alanları");
  expect(props.app_version === "0.1.0", "önceki açılışın sürümü (0.1.0)");
  expect(new Date(anr.occurred_at).getTime() >= started.getTime() - 120_000, "olay zamanı sistemin ANR kaydı");
  expect(Array.isArray(props.frames) && props.frames.length > 0 && props.frames.every((f) => f.column === 0 && typeof f.function === "string"), "JVM çerçeve konumları var");
  const text = JSON.stringify(anr);
  for (const leak of ["Input dispatching timed out (", "Waited", "sysTid", "/data/"]) expect(!text.includes(leak), `olayda yok: ${leak}`);
  expect(!/\b(anonymous|android_id|gaid|adid)\b/i.test(JSON.stringify(props)), "olayda cihaz kimliği yok");

  // 3. Karartılmış çerçeveler aynı derlemenin mapping.txt dosyasıyla özgün kaynağa çözülür (saas-api çözücüsü).
  // r8-mapping.ts bağımlılıksızdır: ESM kopyası Node'un tür ayıklamasıyla doğrudan yüklenir (saas-api paketi CommonJS'tir).
  const resolverModule = join(work, "r8-mapping.mts");
  copyFileSync(join(repoRoot, "services/saas-api/src/modules/app-signals/r8-mapping.ts"), resolverModule);
  const { retraceFrame, scanMapping } = await import(pathToFileURL(resolverModule).href);
  const jvmClass = (frame) => frame.file.replace(/~/g, "$");
  const { classes } = scanMapping(readFileSync(mappingPath, "utf8"), new Set(props.frames.map(jvmClass)));
  const results = props.frames.map((frame) => ({ generated: frame, result: retraceFrame(classes, jvmClass(frame), frame.function, frame.line) }));
  for (const item of results) console.log(`  ${item.generated.file}.${item.generated.function}:${item.generated.line} → ${JSON.stringify(item.result)}`);
  const names = results.flatMap((item) => (item.result.status === "resolved" ? item.result.frames.map((f) => `${f.className}.${f.methodName}`) : []));
  // R8 CheckoutFlow yöntemlerini alıcının içine gömer ve satırları yeniden numaralar: çözüm gömülü çağrıları ve özgün satırı geri getirir.
  expect(results.some((item) => item.result.status === "resolved" && item.result.frames.length > 1), "R8 eşlemesiyle gömülü (inline) çağrılar ve özgün satır çözüldü");
  expect(names.includes("com.feralin.sample.CheckoutFlow.holdLock") || names.includes("com.feralin.sample.CheckoutFlow.freezeMainThread"), "özgün yöntem: CheckoutFlow.holdLock / freezeMainThread");
  console.log("emülatör ANR e2e: GEÇTİ");
} catch (error) {
  console.error(error instanceof Error ? error.message : error);
  exitCode = 1;
} finally {
  if (emulator && existsSync(adbPath)) {
    adb("emu", "kill");
    for (let i = 0; i < 30 && emulator.exitCode === null; i++) await sleep(1000);
    if (emulator.exitCode === null) emulator.kill();
  }
  if (collect) {
    collect.kill();
    for (let i = 0; i < 20 && collect.exitCode === null && collect.signalCode === null; i++) await sleep(250);
  }
  try {
    rmSync(work, { recursive: true, force: true, maxRetries: 5, retryDelay: 500 });
  } catch {
    // Windows'ta çalıştırılabilir dosya kapanırken kilitli kalabilir; geçici dizin işletim sisteminindir.
  }
}
process.exit(exitCode);
