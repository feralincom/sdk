#!/usr/bin/env node
// Android SDK temiz kurulum kanıtı: `:feralin:publishToMavenLocal` (yalnız koşuya özgü yerel Maven dizini, ~/.m2 ve registry değil)
// → boş, tek modüllü Android projesi; kaynağı sdks/android/sample (aynı ekran ve kod), bağımlılık proje değil Maven koordinatı
// `com.feralin:android` → release APK (R8) → kendi emülatörümüzde dokunmayla izin, olay, gönderim, ağ kesik ve geri gönderim →
// gerçek services/collect → collect worker → ClickHouse. Emülatördür, gerçek cihaz değildir; adb kurulumunda Play referrer kanıtı yoktur.
//
//   DATABASE_URL='postgres://...' CLICKHOUSE_URL=http://127.0.0.1:18127 node sdks/android/scripts/e2e-clean-install.mjs
//
// İsteğe bağlı: FERALIN_EMULATOR_PORT (5562), FERALIN_EMULATOR_AVD (Test), FERALIN_ANDROID_COLLECT_PORT (4763, doluysa sonraki boş port), FERALIN_ANDROID_WORK.
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { androidHome, checkOutbox, clickhouseProof, emulator, evidenceDir, installPairingAvailable, isWindows, newInstallCode, pickPort, repo, requireDatabase, run, sleep, startCollect } from "../../../scripts/sdk-e2e/mobile-lib.mjs";

const database = requireDatabase();
const clickhouseUrl = process.env.CLICKHOUSE_URL ?? "http://127.0.0.1:18127";
const port = process.env.FERALIN_EMULATOR_PORT ?? "5562";
const avd = process.env.FERALIN_EMULATOR_AVD ?? "Test";
const collectPort = await pickPort(process.env.FERALIN_ANDROID_COLLECT_PORT ?? "4763");
const projectKey = "pk_test_sdk_android_clean_0001";
const tenant = "tenant_sdk_android_clean";
const project = "proj_sdk_android_clean";
const installCode = newInstallCode();
const android = join(repo, "sdks/android");
const work = process.env.FERALIN_ANDROID_WORK ?? join(tmpdir(), "fr-and-clean");
const m2 = join(work, "m2");
const evidence = evidenceDir("android-clean-install");
const wrapper = join(android, isWindows ? "gradlew.bat" : "gradlew");
const gradleEnv = { ...process.env, ANDROID_HOME: androidHome };

function replaceOnce(text, from, to) {
  if (!text.includes(from)) throw new Error(`örnek build.gradle.kts beklenen biçimde değil: ${from}`);
  return text.replace(from, to);
}

function buildApk(withInstallCode) {
  const version = /^feralinVersion=(\S+)/m.exec(readFileSync(join(android, "gradle.properties"), "utf8"))?.[1];
  if (!version) throw new Error("sdks/android/gradle.properties içinde sürüm yok");
  run(wrapper, [":feralin:publishToMavenLocal", `-Dmaven.repo.local=${m2}`, "--console=plain", "--no-daemon", "-q"], { cwd: android, env: gradleEnv });
  const published = join(m2, "com/feralin/android", version);
  const files = existsSync(published) ? readdirSync(published) : [];
  if (!files.some((name) => name.endsWith(".aar")) || !files.some((name) => name.endsWith(".pom"))) throw new Error(`yerel Maven yayını eksik: ${published}`);
  console.log(`publishToMavenLocal: ${published} (${files.join(", ")})`);

  const consumer = join(work, "consumer");
  mkdirSync(consumer, { recursive: true });
  cpSync(join(android, "sample/src"), join(consumer, "src"), { recursive: true });
  writeFileSync(
    join(consumer, "settings.gradle.kts"),
    [
      "pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }",
      "dependencyResolutionManagement {",
      "    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)",
      "    repositories {",
      '        mavenLocal { content { includeGroup("com.feralin") } }',
      "        google()",
      "        mavenCentral()",
      "    }",
      "}",
      'rootProject.name = "feralin-android-clean"',
      "",
    ].join("\n"),
  );
  writeFileSync(join(consumer, "gradle.properties"), "android.useAndroidX=true\norg.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8\n");
  let build = readFileSync(join(android, "sample/build.gradle.kts"), "utf8");
  build = replaceOnce(build, 'id("com.android.application")', 'id("com.android.application") version "8.13.2"');
  build = replaceOnce(build, 'id("org.jetbrains.kotlin.android")', 'id("org.jetbrains.kotlin.android") version "2.2.20"');
  build = replaceOnce(build, 'implementation(project(":feralin"))', `implementation("com.feralin:android:${version}")`);
  // Release APK kurulabilsin diye makinenin debug anahtarıyla imzalanır; anahtar üretilmez, yayın yapılmaz.
  build = replaceOnce(build, "isMinifyEnabled = true", 'isMinifyEnabled = true\n            signingConfig = signingConfigs.getByName("debug")');
  writeFileSync(join(consumer, "build.gradle.kts"), build);
  run(
    wrapper,
    [
      "-p",
      consumer,
      "assembleRelease",
      `-Dmaven.repo.local=${m2}`,
      `-PfeSampleCollectUrl=http://10.0.2.2:${collectPort}`,
      `-PfeSampleKey=${projectKey}`,
      ...(withInstallCode ? [`-PfeSampleInstallCode=${installCode}`] : []),
      "--console=plain",
      "--no-daemon",
      "-q",
    ],
    { cwd: consumer, env: gradleEnv },
  );
  const out = join(consumer, "build/outputs/apk/release");
  const apk = existsSync(out) ? readdirSync(out).find((name) => name.endsWith(".apk")) : undefined;
  if (!apk) throw new Error("release APK bulunamadı");
  return join(out, apk);
}

const flushPattern = /flush status=(\d+) accepted=(\d+) rejected=(\d+)/;

/** Örneğin kendi düğme metinleri (values ve values-tr); emülatörün sistem dili hangisiyse o eşleşir. */
function sampleStrings(dir) {
  const xml = readFileSync(join(android, "sample/src/main/res", dir, "strings.xml"), "utf8");
  return Object.fromEntries([...xml.matchAll(/<string name="([^"]+)">([^<]*)<\/string>/g)].map((match) => [match[1], match[2]]));
}
const stringsEn = sampleStrings("values");
const stringsTr = sampleStrings("values-tr");
const label = (key) => [stringsEn[key], stringsTr[key]];

let collect;
let device;
let exitCode = 0;
try {
  rmSync(work, { recursive: true, force: true, maxRetries: 3 });
  mkdirSync(work, { recursive: true });
  const pairing = installPairingAvailable({ work, database });
  if (pairing) checkOutbox({ work, database, lines: [`seedinstallcode ${tenant}:${project}:${installCode}`], name: "pairing-seed.txt" });
  else console.log("eşleştirme kodu adımı ATLANDI: veritabanında install_verification_codes yok (saas-api migrasyonlu test veritabanı gerekir)");
  const apk = buildApk(pairing);
  console.log(`APK: ${apk}`);
  collect = await startCollect({ work, database, port: collectPort, projectKey, tenant, project });
  device = emulator({ port, avd });
  const info = await device.boot();
  const steps = [];
  await device.startRecording();
  try {
    device.install(apk, "com.feralin.sample");
    device.clearLog();
    const started = device.adb("shell", "am", "start", "-W", "-n", "com.feralin.sample/.MainActivity");
    if (started.status !== 0) throw new Error(`uygulama açılamadı: ${started.stderr}`);
    // Dokunmalar örnek ekranın kendi düğmeleridir.
    await device.tapText(label("consent_grant_ad"));
    await sleep(3000);
    await device.tapText(label("track_event"));
    await device.tapText(label("flush_now"));
    // Her aşama kendi temiz günlüğünde beklenir (clearLog): sıraya göre arama, tampon dönünce kayardı.
    const online = await device.waitForLog("FeralinSample:I", flushPattern, { dumpDir: evidence });
    steps.push({ step: "cevrimici-ilk", status: Number(online[1]), accepted: Number(online[2]) });
    if (online[1] !== "202") throw new Error(`ilk gönderim 202 değil: ${online[0]}`);

    device.setNetwork(false);
    await sleep(6000);
    device.clearLog();
    await device.tapText(label("track_event"));
    await device.tapText(label("flush_now"));
    const offline = await device.waitForLog("FeralinSample:I", flushPattern, { dumpDir: evidence });
    steps.push({ step: "cevrimdisi", status: Number(offline[1]), accepted: Number(offline[2]) });
    if (offline[1] !== "0") throw new Error(`ağ kesikken gönderim başarısız olmalıydı: ${offline[0]}`);
    device.screenshot(join(evidence, "cevrimdisi-ekran.png"));

    device.setNetwork(true);
    await sleep(8000);
    device.clearLog();
    // SDK ağ geri gelince kendisi de gönderebilir; bu durumda elle gönderim boş kuyrukla 0 döner. Asıl kanıt ClickHouse sayımıdır.
    await device.tapText(label("flush_now"));
    const back = await device.waitForLog("FeralinSample:I", flushPattern, { dumpDir: evidence });
    steps.push({ step: "cevrimici", status: Number(back[1]), accepted: Number(back[2]) });
    await sleep(1000);
    await device.tapText(label("flush_now"));
    await sleep(1500);
  } finally {
    device.screenshot(join(evidence, "son-ekran.png"));
    const recorded = await device.stopRecording(join(evidence, "video.mp4"));
    console.log(`video: ${recorded ? join(evidence, "video.mp4") : "alınamadı"}`);
  }
  console.log(JSON.stringify(steps));
  writeFileSync(join(evidence, "adimlar.json"), `${JSON.stringify({ device: info, steps }, null, 2)}\n`);
  await clickhouseProof({
    binary: collect.binary,
    work,
    database,
    clickhouseUrl,
    label: "android_clean",
    // İlk açılış 1 + iki dokunma olayı (biri çevrimdışı kuyruktan) = 3 satır.
    discover: { sql: `SELECT event_id FROM {db}.events FINAL WHERE tenant_id = '${tenant}' FORMAT TSV`, count: 3 },
    evidenceFile: join(evidence, "clickhouse.txt"),
    extra: [
      {
        label: "olay türleri, SDK ve platform",
        sql: `SELECT event_name, sdk_name, platform, count() FROM {db}.events FINAL WHERE tenant_id = '${tenant}' GROUP BY event_name, sdk_name, platform ORDER BY event_name FORMAT TSV`,
        expect: (text) =>
          text === "app_first_open\tferalin-android\tandroid\t1\nsample_button_clicked\tferalin-android\tandroid\t2" ? null : `beklenmeyen dağılım: ${text}`,
      },
      {
        label: "kurulum kaynağı (adb kurulumu, Play referrer kanıtı yok)",
        sql: `SELECT JSONExtractString(properties, 'attribution_source') FROM {db}.events FINAL WHERE tenant_id = '${tenant}' AND event_name = 'app_first_open' FORMAT TSV`,
        expect: (text) => (text === "none" ? null : `beklenen none, gelen: ${text}`),
      },
      {
        label: "eşleştirme kodu kalıcı olay verisinde yok",
        sql: `SELECT count() FROM {db}.events WHERE tenant_id = '${tenant}' AND (positionCaseInsensitive(properties, 'fr_install_code') > 0 OR position(properties, '${installCode}') > 0) FORMAT TSV`,
        expect: (text) => (text === "0" ? null : `kod ${text} olay satırında kaldı`),
      },
    ],
  });
  if (pairing) {
    // Kodu SDK'nın kendisi gönderdi (uygulama yalnız yapılandırmaya yazdı): süreçte kuyruğa giren ilk olay `app_first_open`.
    // Toplayıcı yayın turunda satırı eşleştirdi ve kodu yayınlanmış outbox satırından söktü.
    checkOutbox({ work, database, lines: [`installcodematched ${tenant}:${project}:${installCode}:app_first_open:android:feralin-android`, `absent ${installCode}`], name: "pairing-check.txt" });
    writeFileSync(join(evidence, "eslestirme.txt"), `kod öneki ${installCode.slice(0, 4)}: app_first_open ile eşleşti (feralin-android, android); kod outbox ve ClickHouse verisinde yok\n`);
  }
  console.log(`kanıt: ${evidence}`);
  console.log(`E2E android temiz kurulum (publishToMavenLocal → boş proje → emülatör → ClickHouse${pairing ? " → eşleştirme kodu kanıtı" : "; eşleştirme kodu adımı atlandı"}): GEÇTİ (emülatör, gerçek cihaz değil)`);
} catch (err) {
  exitCode = 1;
  console.error(`E2E android temiz kurulum: KALDI: ${err instanceof Error ? err.message : String(err)}`);
  if (collect) console.error(collect.logLines.join("").slice(-1500));
} finally {
  await device?.kill();
  collect?.child.kill();
}
process.exit(exitCode);
