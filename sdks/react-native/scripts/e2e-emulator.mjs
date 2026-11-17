#!/usr/bin/env node
// Emülatörde gerçek olay: `npm pack` çıktısı temiz bir React Native projesine kurulur, release APK derlenir, kendi emülatörümüzde
// çalışır ve olaylar gerçek services/collect üzerinden collect_outbox'ta doğrulanır. Başka emülatöre dokunulmaz: kendi portunda
// `-read-only` açılır ve yalnız o kapatılır.
//   DATABASE_URL='postgres://...' node sdks/react-native/scripts/e2e-emulator.mjs
// İsteğe bağlı: FERALIN_RN_WORK (kısa çalışma yolu, Windows yol sınırı), FERALIN_RN_AVD, FERALIN_RN_EMULATOR_PORT, FERALIN_RN_VERSION.
import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const repo = join(root, "../..");
const isWindows = process.platform === "win32";
const database = process.env.DATABASE_URL;
if (!database) {
  console.error("HATA: DATABASE_URL zorunlu (yalnız test veritabanı)");
  process.exit(1);
}
const androidHome = process.env.ANDROID_HOME ?? (isWindows ? join(process.env.LOCALAPPDATA, "Android/Sdk") : join(process.env.HOME, "Android/Sdk"));
const adbPath = join(androidHome, "platform-tools", isWindows ? "adb.exe" : "adb");
const emulatorPath = join(androidHome, "emulator", isWindows ? "emulator.exe" : "emulator");
const emulatorPort = process.env.FERALIN_RN_EMULATOR_PORT ?? "5582";
const serial = `emulator-${emulatorPort}`;
const avd = process.env.FERALIN_RN_AVD ?? "Test";
const rnVersion = process.env.FERALIN_RN_VERSION ?? "0.87.1";
const collectPort = process.env.FERALIN_RN_COLLECT_PORT ?? "4702";
const projectKey = "pk_test_sdk_rn_e2e_0001";
const work = process.env.FERALIN_RN_WORK ?? join(tmpdir(), "fr-rn");
const appName = "FeralinRnE2E";
const appDir = join(work, appName);

function run(command, args, options = {}) {
  console.log(`$ ${command} ${args.join(" ")}`);
  const shellTool = isWindows && (["npm", "npx"].includes(command) || command.endsWith("gradlew.bat"));
  const [file, argv] = shellTool ? ["cmd.exe", ["/d", "/c", command, ...args]] : [command, args];
  const result = spawnSync(file, argv, { stdio: "inherit", ...options });
  if (result.status !== 0) throw new Error(`komut başarısız (${result.status ?? result.error}): ${command} ${args.join(" ")}`);
}

const adb = (...args) => spawnSync(adbPath, ["-s", serial, ...args], { encoding: "utf8" });
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function startCollect() {
  const binary = join(work, isWindows ? "collect.exe" : "collect");
  run("go", ["build", "-o", binary, "./cmd/collect"], { cwd: join(repo, "services/collect") });
  const child = spawn(binary, [], {
    env: { ...process.env, COLLECT_ADDR: `127.0.0.1:${collectPort}`, DATABASE_URL: database, COLLECT_AUTO_MIGRATE: "true", COLLECT_PROJECT_KEYS: `${projectKey}=tenant_sdk_rn:proj_sdk_rn` },
    stdio: "ignore",
  });
  for (let i = 0; i < 120; i++) {
    await sleep(500);
    try {
      const health = await (await fetch(`http://127.0.0.1:${collectPort}/v1/health`)).text();
      if (health.includes('"outbox":"postgres"')) {
        console.log(`health: ${health.trim()}`);
        return child;
      }
    } catch {
      // henüz dinlemiyor
    }
  }
  throw new Error("collect açılmadı");
}

async function bootEmulator() {
  const child = spawn(emulatorPath, ["-avd", avd, "-port", emulatorPort, "-no-window", "-read-only", "-no-audio", "-no-boot-anim", "-no-snapshot"], { stdio: "ignore", detached: false });
  for (let i = 0; i < 300; i++) {
    await sleep(2000);
    if (child.exitCode !== null) throw new Error(`emülatör çıktı (${child.exitCode}); AVD başka süreçte kullanılıyor olabilir`);
    if (adb("shell", "getprop", "sys.boot_completed").stdout?.trim() === "1") {
      console.log(`emülatör hazır: ${serial} (${avd}), API ${adb("shell", "getprop", "ro.build.version.sdk").stdout.trim()}`);
      return child;
    }
  }
  throw new Error("emülatör 10 dakikada açılmadı");
}

function createApp() {
  // FERALIN_RN_REUSE=1: yalnız yeniden deneme için; temiz kurulum kanıtı sayılmaz.
  if (!(process.env.FERALIN_RN_REUSE && existsSync(appDir))) {
    rmSync(work, { recursive: true, force: true, maxRetries: 3 });
    mkdirSync(work, { recursive: true });
    // Yalnız bu çalışma için tek seferlik; proje bağımlılığı olmaz.
    run("npx", ["-y", "@react-native-community/cli@20.2.0", "init", appName, "--version", rnVersion, "--skip-git-init", "--install-pods", "false"], { cwd: work });
    const packDir = join(work, "pack");
    mkdirSync(packDir);
    run("npm", ["pack", "--pack-destination", packDir], { cwd: root });
    const tarball = join(packDir, readdirSync(packDir).find((name) => name.endsWith(".tgz")));
    run("npm", ["install", "--no-audit", "--no-fund", tarball], { cwd: appDir });
  }

  const app = readFileSync(join(root, "e2e/App.tsx"), "utf8").replaceAll("__COLLECT_PORT__", collectPort).replaceAll("__PROJECT_KEY__", projectKey);
  writeFileSync(join(appDir, "App.tsx"), app);
  // Yalnız bu test uygulaması 10.0.2.2 adresine http ile bağlanır.
  const manifestPath = join(appDir, "android/app/src/main/AndroidManifest.xml");
  const manifest = readFileSync(manifestPath, "utf8").replace(/android:usesCleartextTraffic="[^"]*"/, 'android:usesCleartextTraffic="true"');
  writeFileSync(manifestPath, manifest);
  return join(appDir, "android");
}

function buildApk(androidDir) {
  const gradle = isWindows ? join(androidDir, "gradlew.bat") : "./gradlew";
  run(gradle, ["assembleRelease", "-PreactNativeArchitectures=x86_64", "--console=plain", "-q"], { cwd: androidDir, env: { ...process.env, ANDROID_HOME: androidHome } });
  return join(androidDir, "app/build/outputs/apk/release/app-release.apk");
}

/** logcat'i izler; `RN_E2E` satırları adımlara dönüşür. */
function watchLogcat(onStep) {
  const child = spawn(adbPath, ["-s", serial, "logcat", "-v", "raw", "-s", "ReactNativeJS:I"], { stdio: ["ignore", "pipe", "ignore"] });
  let buffer = "";
  child.stdout.on("data", (chunk) => {
    buffer += chunk.toString();
    let newline = buffer.indexOf("\n");
    while (newline >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      const at = line.indexOf("RN_E2E ");
      if (at >= 0) onStep(JSON.parse(line.slice(at + 7)));
      newline = buffer.indexOf("\n");
    }
  });
  return child;
}

function setNetwork(enabled) {
  const state = enabled ? "enable" : "disable";
  adb("shell", "svc", "wifi", state);
  adb("shell", "svc", "data", state);
  console.log(`emülatör ağı: ${state}`);
}

async function runScenario(apk) {
  const pkg = "com.feralinrne2e";
  const installed = adb("install", "-r", apk);
  if (installed.status !== 0) throw new Error(`kurulum başarısız: ${installed.stdout}${installed.stderr}`);
  adb("logcat", "-c");
  const steps = new Map();
  let resolveDone;
  let rejectDone;
  const done = new Promise((resolve, reject) => {
    resolveDone = resolve;
    rejectDone = reject;
  });
  const timer = setTimeout(() => rejectDone(new Error(`senaryo zaman aşımı; görülen adımlar: ${[...steps.keys()].join(", ")}`)), 240_000);
  const logcat = watchLogcat((step) => {
    steps.set(step.step, step);
    console.log(`  ${JSON.stringify(step)}`);
    if (step.step === "wait-offline") setNetwork(false);
    if (step.step === "wait-online") setNetwork(true);
    if (step.step === "error") rejectDone(new Error(`uygulama hatası: ${step.name}`));
    if (step.step === "done") resolveDone();
  });
  try {
    const started = adb("shell", "am", "start", "-W", "-n", `${pkg}/.MainActivity`);
    if (started.status !== 0) throw new Error(`uygulama açılamadı: ${started.stderr}`);
    await done;
  } finally {
    clearTimeout(timer);
    logcat.kill();
    setNetwork(true);
  }
  return steps;
}

function verify(steps) {
  const get = (name) => {
    const step = steps.get(name);
    if (!step) throw new Error(`adım yok: ${name}`);
    return step;
  };
  const expect = (condition, message) => {
    if (!condition) throw new Error(`KALDI: ${message}`);
  };
  const lines = [];
  expect(get("initialize").ready === true, "initialize true olmalı");
  expect(get("izin-yok").event_id === null && get("izin-yok").queued === 0, "izinsiz olay üretilmemeli");
  expect(get("izin-yok").sdk === "@feralin/react-native", "sarmalayıcı kimliği görünmeli");
  const noAd = get("reklam-izni-yok");
  expect(noAd.drained === true && noAd.event_id, "reklam izni yokken olay gönderilmeli");
  lines.push(`nofrclickevent ${noAd.event_id}`, `once ${noAd.event_id}`, `platform react_native:${noAd.event_id}`);
  const withAd = get("reklam-izni-var");
  expect(withAd.status === 202 && withAd.event_id, "reklam izni varken 202 bekleniyordu");
  lines.push(`frclick ${withAd.batch_id}`, `once ${withAd.event_id}`, `platform react_native:${withAd.event_id}`);
  expect(get("opt-out").event_id === null && get("opt-out").queued === 0, "opt-out sonrası olay üretilmemeli");
  const offline = get("cevrimdisi");
  expect(offline.network_off === true, "ağ kapanmış olmalı");
  expect(offline.event_id && offline.queued >= 1, "çevrimdışı olay kuyrukta kalmalı");
  const online = get("cevrimici");
  expect(online.network_on === true && online.drained === true && online.queued === 0, "ağ gelince kuyruk boşalmalı");
  lines.push(`once ${online.event_id}`, `platform react_native:${online.event_id}`);
  return lines;
}

let collect;
let emulator;
let exitCode = 0;
try {
  const androidDir = createApp();
  const apk = buildApk(androidDir);
  console.log(`APK: ${apk}`);
  collect = await startCollect();
  emulator = await bootEmulator();
  const steps = await runScenario(apk);
  const checks = join(work, "checks.txt");
  writeFileSync(checks, `${verify(steps).join("\n")}\n`);
  run("go", ["run", join(repo, "sdks/android/scripts/outbox_check.go"), checks], { cwd: join(repo, "services/collect") });
  console.log("E2E react-native emülatör: GEÇTİ");
} catch (err) {
  exitCode = 1;
  console.error(`E2E react-native emülatör: KALDI: ${err instanceof Error ? err.message : String(err)}`);
} finally {
  if (emulator && existsSync(adbPath)) {
    adb("emu", "kill");
    await sleep(3000);
    if (emulator.exitCode === null) emulator.kill();
  }
  collect?.kill();
}
process.exit(exitCode);
