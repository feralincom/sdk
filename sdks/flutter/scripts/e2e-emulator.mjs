#!/usr/bin/env node
// Flutter SDK emülatör uçtan uca kanıtı (QA-D, F3-E01-T02): init → izin → kurulum kaynağı → ekran → satın alma → ağ kesik
// (çevrimdışı kuyruk) → ağ geri (gönderim) → gerçek services/collect → collect worker → ClickHouse satırı.
// Emülatördür, gerçek cihaz değildir; kurulum adb ile yapıldığından Play Install Referrer kanıtı yoktur ve kaynak dürüstçe `none` beklenir.
//
//   DATABASE_URL='postgres://...' CLICKHOUSE_URL=http://127.0.0.1:18127 node sdks/flutter/scripts/e2e-emulator.mjs [example|git|path]
//
// Kaynak: `example` (varsayılan) sdks/flutter/example uygulamasını (path bağımlılığı) derler. `git` ve `path` temiz kurulumdur:
// `flutter create` ile boş proje açılır, paket pub.dev dışından (HEAD'deki paket ağacından kurulan yerel git deposu ya da dizin yolu) eklenir,
// senaryo girişi kopyalanır. İsteğe bağlı: FERALIN_EMULATOR_PORT (5562), FERALIN_EMULATOR_AVD (Test), FERALIN_FLUTTER_COLLECT_PORT (4761, doluysa sonraki boş port),
// FERALIN_FLUTTER_WORK (kısa çalışma yolu), FERALIN_EMULATOR_REUSE=1 (açık kendi emülatörünü kullan, kapatma).
import { spawnSync } from "node:child_process";
import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
import { checkOutbox, clickhouseProof, emulator, evidenceDir, installPairingAvailable, newInstallCode, pickPort, repo, requireDatabase, run, startCollect } from "../../../scripts/sdk-e2e/mobile-lib.mjs";

const source = process.argv[2] ?? "example";
if (!["example", "git", "path"].includes(source)) {
  console.error("kullanım: e2e-emulator.mjs [example|git|path]");
  process.exit(2);
}
const database = requireDatabase();
const clickhouseUrl = process.env.CLICKHOUSE_URL ?? "http://127.0.0.1:18127";
const port = process.env.FERALIN_EMULATOR_PORT ?? "5562";
const avd = process.env.FERALIN_EMULATOR_AVD ?? "Test";
const collectPort = await pickPort(process.env.FERALIN_FLUTTER_COLLECT_PORT ?? "4761");
const projectKey = "pk_test_sdk_flutter_emu_0001";
const tenant = "tenant_sdk_flutter_emu";
const project = "proj_sdk_flutter_emu";
const installCode = newInstallCode();
const sdk = join(repo, "sdks/flutter");
const work = process.env.FERALIN_FLUTTER_WORK ?? join(tmpdir(), `fr-fl-${source}`);
const runId = `${source}_${Date.now()}`;
const evidence = evidenceDir(`flutter-${source}`);

function prepareExample() {
  const app = join(sdk, "example");
  run("flutter", ["pub", "get"], { cwd: app });
  return { app, component: "com.feralin.feralin_flutter_example/.MainActivity", target: "lib/e2e_main.dart" };
}

/**
 * Paket ağacı HEAD commit'inden (çalışma ağacındaki işlenmemiş değişiklikler girmez) tek commit'lik yerel bir git deposuna
 * konur. Ana depo doğrudan verilmez: worktree üzerinden `git clone --mirror` bütün dalları taşıdığından bu makinede takıldı.
 * Uzak barındırma (GitHub vb.) sınanmış olmaz; sınanan pub'ın git kaynağı çözümüdür.
 */
function packageGitRepo() {
  const head = spawnSync("git", ["rev-parse", "HEAD"], { cwd: repo, encoding: "utf8" }).stdout.trim();
  if (!/^[0-9a-f]{40}$/.test(head)) throw new Error("git HEAD okunamadı");
  const gitRepo = join(work, "feralin-flutter-git");
  mkdirSync(gitRepo, { recursive: true });
  // Dosyalar commit'ten okunur (tar aracının Windows/MSYS yol farkına girilmez).
  const files = spawnSync("git", ["ls-tree", "-r", "--name-only", head, "sdks/flutter"], { cwd: repo, encoding: "utf8" }).stdout.split("\n").filter(Boolean);
  if (!files.includes("sdks/flutter/pubspec.yaml")) throw new Error("commit'te sdks/flutter/pubspec.yaml yok");
  for (const file of files) {
    const blob = spawnSync("git", ["cat-file", "blob", `${head}:${file}`], { cwd: repo, maxBuffer: 64 * 1024 * 1024 });
    if (blob.status !== 0) throw new Error(`okunamadı: ${file}`);
    mkdirSync(dirname(join(gitRepo, file)), { recursive: true });
    writeFileSync(join(gitRepo, file), blob.stdout);
  }
  console.log(`paket ağacı: ${files.length} dosya (${head})`);
  const git = (...args) => run("git", ["-c", "user.name=feralin-e2e", "-c", "user.email=e2e@feralin.invalid", "-c", "core.autocrlf=false", ...args], { cwd: gitRepo });
  git("init", "-q", "-b", "main");
  git("add", "-A");
  git("commit", "-q", "-m", `feralin_flutter ${head}`);
  const ref = spawnSync("git", ["rev-parse", "HEAD"], { cwd: gitRepo, encoding: "utf8" }).stdout.trim();
  console.log(`paket git deposu: ${gitRepo} (kaynak commit ${head}, paket commit ${ref})`);
  writeFileSync(join(evidence, "git-kaynak.txt"), `kaynak depo commit: ${head}\npaket git commit: ${ref}\n`);
  return { url: pathToFileURL(gitRepo).href, ref };
}

/** Boş Flutter projesi; paket pub.dev dışından gelir. Kanıt: pubspec.lock içindeki kaynak satırı. */
function prepareClean() {
  const app = join(work, "fr_flutter_clean");
  run("flutter", ["create", "--org", "com.feralin.e2e", "--platforms", "android", "--project-name", "fr_flutter_clean", app]);
  let dependency;
  if (source === "git") {
    const { url, ref } = packageGitRepo();
    // Git URL'si: pub, uzaktaki bir Git deposundaki gibi klonlar ve verilen commit'i çözer.
    dependency = `  feralin_flutter:\n    git:\n      url: ${url}\n      path: sdks/flutter\n      ref: ${ref}\n`;
  } else {
    dependency = `  feralin_flutter:\n    path: ${sdk.replaceAll("\\", "/")}\n`;
  }
  const pubspecPath = join(app, "pubspec.yaml");
  const pubspec = readFileSync(pubspecPath, "utf8").replace(/\r\n/g, "\n");
  const anchor = "dependencies:\n  flutter:\n    sdk: flutter\n";
  if (!pubspec.includes(anchor)) throw new Error("flutter create pubspec.yaml biçimi beklenenden farklı");
  writeFileSync(pubspecPath, pubspec.replace(anchor, `${anchor}${dependency}`));
  rmSync(join(app, "test"), { recursive: true, force: true });
  writeFileSync(join(app, "lib/main.dart"), readFileSync(join(sdk, "example/lib/e2e_main.dart"), "utf8"));
  // Yalnız bu test uygulaması emülatörden ana makinenin yerel toplayıcısına (10.0.2.2) düz HTTP ile bağlanır.
  const xmlDir = join(app, "android/app/src/main/res/xml");
  mkdirSync(xmlDir, { recursive: true });
  cpSync(join(sdk, "example/android/app/src/main/res/xml/network_security_config.xml"), join(xmlDir, "network_security_config.xml"));
  const manifestPath = join(app, "android/app/src/main/AndroidManifest.xml");
  const manifest = readFileSync(manifestPath, "utf8");
  if (!manifest.includes("<application")) throw new Error("AndroidManifest.xml beklenen biçimde değil");
  writeFileSync(manifestPath, manifest.replace("<application", '<application android:networkSecurityConfig="@xml/network_security_config"'));
  run("flutter", ["pub", "get"], { cwd: app });
  const lock = readFileSync(join(app, "pubspec.lock"), "utf8").replace(/\r\n/g, "\n");
  const entry = /\n {2}feralin_flutter:\n(?: {4}.*\n)+/.exec(lock)?.[0]?.trim();
  if (!entry || !entry.includes(`source: ${source}`)) throw new Error(`pubspec.lock feralin_flutter kaynağı ${source} değil:\n${entry}`);
  console.log(`temiz kurulum (pubspec.lock):\n${entry}`);
  writeFileSync(join(evidence, "pubspec-lock-feralin.txt"), `${entry}\n`);
  return { app, component: "com.feralin.e2e.fr_flutter_clean/.MainActivity", target: "lib/main.dart" };
}

function buildApk({ app, target }, withInstallCode) {
  run("flutter", [
    "build",
    "apk",
    "--release",
    "-t",
    target,
    "--target-platform",
    "android-x64",
    `--dart-define=FERALIN_COLLECT_URL=http://10.0.2.2:${collectPort}`,
    `--dart-define=FERALIN_PROJECT_KEY=${projectKey}`,
    `--dart-define=FERALIN_E2E_RUN=${runId}`,
    ...(withInstallCode ? [`--dart-define=FERALIN_INSTALL_CODE=${installCode}`] : []),
  ], { cwd: app });
  const apk = join(app, "build/app/outputs/flutter-apk/app-release.apk");
  if (!existsSync(apk)) throw new Error(`APK yok: ${apk}`);
  return apk;
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
  const init = get("initialize");
  expect(init.ready === true && init.sdk === "feralin-flutter", "initialize true ve sdk feralin-flutter olmalı");
  expect(get("izin-yok").event_id === null && get("izin-yok").queued === 0, "izinsiz olay üretilmemeli");
  const consent = get("izin");
  expect(consent.analytics === true && consent.advertising === true && consent.anonymous_id, "izin ve anonim kimlik olmalı");
  const first = get("cevrimici-ilk");
  // Ön plandayken SDK kendi zamanlayıcısıyla da gönderir; açık flush o gönderim sürerken ya da sonra boş sonuç (0) dönebilir.
  // Bu yüzden durum kodu 0 ya da 202 kabul edilir; kanıt ağ kesilmeden önce boşalan kuyruk + outbox + ClickHouse satırıdır.
  expect(first.queued === 0 && [0, 202].includes(first.status) && first.screen_event_id && first.purchase_event_id, "ilk gönderimde kuyruk boşalmalı");
  const offline = get("cevrimdisi");
  expect(offline.network_off === true, "ağ kesilmiş olmalı");
  expect(offline.event_id && offline.status === 0 && offline.queued >= 1, "çevrimdışı olay kuyrukta kalmalı");
  const online = get("cevrimici");
  // Ağ gelince SDK kendisi de gönderebilir (açık çağrı o zaman boş kuyrukla 0 döner); kanıt boş kuyruk ve ClickHouse satırıdır.
  expect(online.network_on === true && online.queued === 0 && [0, 202].includes(online.status), "ağ gelince kuyruk boşalmalı");
  const ids = [first.screen_event_id, first.purchase_event_id, offline.event_id];
  return { ids, anonymousId: consent.anonymous_id };
}

let collect;
let device;
let exitCode = 0;
try {
  rmSync(work, { recursive: true, force: true, maxRetries: 3 });
  mkdirSync(work, { recursive: true });
  const prepared = source === "example" ? prepareExample() : prepareClean();
  // Eşleştirme kodu senaryo girişinin yapılandırmasından okunur; `git` kaynağı HEAD'deki paketi kurar, o yüzden kod desteği commit'te olmalıdır.
  const pairing = installPairingAvailable({ work, database });
  if (pairing) checkOutbox({ work, database, lines: [`seedinstallcode ${tenant}:${project}:${installCode}`], name: "pairing-seed.txt" });
  else console.log("eşleştirme kodu adımı ATLANDI: veritabanında install_verification_codes yok (saas-api migrasyonlu test veritabanı gerekir)");
  const apk = buildApk(prepared, pairing);
  console.log(`APK: ${apk}`);
  collect = await startCollect({ work, database, port: collectPort, projectKey, tenant, project });
  device = emulator({ port, avd });
  const info = await device.boot();
  await device.startRecording();
  let steps;
  try {
    steps = await device.runScenario({ apk, component: prepared.component, filterSpec: "flutter:I", prefix: "FR_E2E" });
  } finally {
    device.screenshot(join(evidence, "son-ekran.png"));
    const recorded = await device.stopRecording(join(evidence, "video.mp4"));
    console.log(`video: ${recorded ? join(evidence, "video.mp4") : "alınamadı"}`);
  }
  const { ids, anonymousId } = verify(steps);
  writeFileSync(join(evidence, "adimlar.json"), `${JSON.stringify({ source, runId, device: info, steps: [...steps.values()] }, null, 2)}\n`);
  checkOutbox({ work, database, lines: ids.flatMap((id) => [`once ${id}`, `platform flutter_android:${id}`, `nofrclickevent ${id}`]) });
  await clickhouseProof({
    binary: collect.binary,
    work,
    database,
    clickhouseUrl,
    label: `flutter_${source}`,
    eventIds: ids,
    evidenceFile: join(evidence, "clickhouse.txt"),
    extra: [
      {
        // Kurulum kaynağı: adb kurulumunda Play referrer kanıtı yoktur; ilk açılış tek ve `none` olmalıdır.
        label: "ilk açılış ve kurulum kaynağı (anonim kimlikle)",
        sql: `SELECT event_name, JSONExtractString(properties, 'attribution_source') AS attribution_source, platform, count() AS n FROM {db}.events FINAL WHERE anonymous_id = '${anonymousId.replace(/[^0-9A-Za-z_-]/g, "")}' AND event_name = 'app_first_open' GROUP BY event_name, attribution_source, platform FORMAT TSV`,
        expect: (text) => (text === "app_first_open\tnone\tflutter_android\t1" ? null : `beklenen tek satır none, gelen: ${text || "(boş)"}`),
      },
      {
        label: "satın alma olayları (feralin_purchase) tutar ve para birimi",
        sql: `SELECT event_id, JSONExtractString(properties, 'transaction_id') AS tx, JSONExtractRaw(properties, 'amount_minor') AS amount, JSONExtractString(properties, 'currency') AS currency, provenance FROM {db}.events FINAL WHERE event_id IN ('${ids[1]}', '${ids[2]}') ORDER BY tx FORMAT TSV`,
        expect: (text) => (text.split("\n").length === 2 && text.includes("4999") && text.includes("1999") ? null : `iki satın alma satırı bekleniyordu: ${text}`),
      },
    ],
  });
  if (pairing) {
    // Kodu SDK'nın kendisi gönderdi: süreçte kuyruğa giren ilk olay izin verilince üretilen `app_first_open`.
    checkOutbox({ work, database, lines: [`installcodematched ${tenant}:${project}:${installCode}:app_first_open:flutter_android:feralin-flutter`, `absent ${installCode}`], name: "pairing-check.txt" });
    writeFileSync(join(evidence, "eslestirme.txt"), `kod öneki ${installCode.slice(0, 4)}: app_first_open ile eşleşti (feralin-flutter, flutter_android); kod outbox ve ClickHouse verisinde yok\n`);
  }
  console.log(`kanıt: ${evidence}`);
  console.log(`E2E flutter emülatör (${source}${pairing ? "; eşleştirme kodu kanıtı" : "; eşleştirme kodu adımı atlandı"}): GEÇTİ (emülatör, gerçek cihaz değil)`);
} catch (err) {
  exitCode = 1;
  console.error(`E2E flutter emülatör (${source}): KALDI: ${err instanceof Error ? err.message : String(err)}`);
  if (collect) console.error(collect.logLines.join("").slice(-1500));
} finally {
  await device?.kill();
  collect?.child.kill();
}
process.exit(exitCode);
