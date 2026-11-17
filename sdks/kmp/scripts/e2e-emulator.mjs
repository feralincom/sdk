#!/usr/bin/env node
// KMP SDK Android hedefi (Ktor OkHttp motoru) emülatörde gerçek toplayıcıya: paket yerel Maven dizinine yayımlanır (registry değil),
// boş dizine kopyalanan Android tüketicisi (examples/android-e2e) oradan kurar, release APK (R8) derlenir, kendi emülatörümüzde
// çalışır; olaylar services/collect outbox'ında ve collect worker ile ClickHouse'ta doğrulanır. Emülatördür, gerçek cihaz değildir.
//
//   DATABASE_URL='postgres://...' CLICKHOUSE_URL=http://127.0.0.1:18127 node sdks/kmp/scripts/e2e-emulator.mjs
//
// İsteğe bağlı: FERALIN_EMULATOR_PORT (5562), FERALIN_EMULATOR_AVD (Test), FERALIN_KMP_COLLECT_PORT (4762, doluysa sonraki boş port), FERALIN_KMP_WORK.
import { cpSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { androidHome, checkOutbox, clickhouseProof, emulator, evidenceDir, isWindows, pickPort, repo, requireDatabase, run, startCollect } from "../../../scripts/sdk-e2e/mobile-lib.mjs";

const database = requireDatabase();
const clickhouseUrl = process.env.CLICKHOUSE_URL ?? "http://127.0.0.1:18127";
const port = process.env.FERALIN_EMULATOR_PORT ?? "5562";
const avd = process.env.FERALIN_EMULATOR_AVD ?? "Test";
const collectPort = await pickPort(process.env.FERALIN_KMP_COLLECT_PORT ?? "4762");
const projectKey = "pk_test_sdk_kmp_android_0001";
const sdk = join(repo, "sdks/kmp");
const work = process.env.FERALIN_KMP_WORK ?? join(tmpdir(), "fr-kmp-android");
const evidence = evidenceDir("kmp-android");
const wrapper = join(repo, "sdks/android", isWindows ? "gradlew.bat" : "gradlew");
const gradleEnv = { ...process.env, ANDROID_HOME: androidHome };

function buildApk() {
  const version = /^feralinVersion=(\S+)/m.exec(readFileSync(join(sdk, "gradle.properties"), "utf8"))?.[1];
  if (!version) throw new Error("sdks/kmp/gradle.properties içinde sürüm yok");
  const localRepo = pathToFileURL(join(work, "maven-repo")).href;
  // Android hedefi ANDROID_HOME ile kurulur; bütün yayınlar yalnız yerel dizine yazılır (iOS macOS dışında atlanır).
  run(wrapper, ["-p", sdk, "publishAllPublicationsToLocalE2ERepository", `-PferalinLocalRepo=${localRepo}`, "--console=plain", "--no-daemon", "-q"], {
    cwd: repo,
    env: gradleEnv,
  });
  const published = join(work, "maven-repo/com/feralin/feralin-kmp-android", version);
  if (!existsSync(published)) throw new Error(`Android yayını yok: ${published}`);
  console.log(`yerel Maven: ${published}`);
  const consumer = join(work, "consumer");
  cpSync(join(sdk, "examples/android-e2e"), consumer, { recursive: true, filter: (src) => !/[\\/](build|\.gradle|\.kotlin)([\\/]|$)/.test(src) });
  writeFileSync(join(consumer, "gradle.properties"), "android.useAndroidX=true\norg.gradle.jvmargs=-Xmx2g -Dfile.encoding=UTF-8\n");
  run(
    wrapper,
    [
      "-p",
      consumer,
      "assembleRelease",
      `-PferalinLocalRepo=${localRepo}`,
      `-PferalinVersion=${version}`,
      `-PfeE2eCollectUrl=http://10.0.2.2:${collectPort}`,
      `-PfeE2eKey=${projectKey}`,
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

function verify(steps) {
  const get = (name) => {
    const step = steps.get(name);
    if (!step) throw new Error(`adım yok: ${name}`);
    return step;
  };
  const expect = (condition, message) => {
    if (!condition) throw new Error(`KALDI: ${message}`);
  };
  expect(get("initialize").sdk === "feralin-kmp" && get("initialize").network_ready === true, "sdk feralin-kmp ve ağ hazır olmalı");
  expect(get("izin-yok").event_id === null && get("izin-yok").queued === 0, "izinsiz olay üretilmemeli");
  const first = get("cevrimici-ilk");
  expect(first.status === 202 && first.accepted === 2 && first.queued === 0, "ilk gönderim 202, 2 kabul olmalı");
  const offline = get("cevrimdisi");
  expect(offline.network_off === true && offline.event_id && offline.status === 0 && offline.queued === 1, "çevrimdışı olay kuyrukta kalmalı");
  const online = get("cevrimici");
  expect(online.network_on === true && online.status === 202 && online.queued === 0, "ağ gelince kuyruk boşalmalı");
  return { ids: [first.screen_event_id, first.order_event_id, offline.event_id], batchId: first.batch_id };
}

let collect;
let device;
let exitCode = 0;
try {
  rmSync(work, { recursive: true, force: true, maxRetries: 3 });
  mkdirSync(work, { recursive: true });
  const apk = buildApk();
  console.log(`APK: ${apk}`);
  collect = await startCollect({ work, database, port: collectPort, projectKey, tenant: "tenant_sdk_kmp_android", project: "proj_sdk_kmp_android" });
  device = emulator({ port, avd });
  const info = await device.boot();
  await device.startRecording();
  let steps;
  try {
    steps = await device.runScenario({ apk, component: "com.feralin.kmpe2e/.MainActivity", filterSpec: "FeralinE2E:I", prefix: "FR_E2E" });
  } finally {
    device.screenshot(join(evidence, "son-ekran.png"));
    const recorded = await device.stopRecording(join(evidence, "video.mp4"));
    console.log(`video: ${recorded ? join(evidence, "video.mp4") : "alınamadı"}`);
  }
  const { ids } = verify(steps);
  writeFileSync(join(evidence, "adimlar.json"), `${JSON.stringify({ device: info, steps: [...steps.values()] }, null, 2)}\n`);
  checkOutbox({ work, database, lines: ids.flatMap((id) => [`once ${id}`, `platform android:${id}`]) });
  await clickhouseProof({
    binary: collect.binary,
    work,
    database,
    clickhouseUrl,
    label: "kmp_android",
    eventIds: ids,
    evidenceFile: join(evidence, "clickhouse.txt"),
    extra: [
      {
        label: "SDK adı ve platform",
        sql: `SELECT DISTINCT sdk_name, platform FROM {db}.events FINAL WHERE event_id IN (${ids.map((id) => `'${id}'`).join(",")}) FORMAT TSV`,
        expect: (text) => (text === "feralin-kmp\tandroid" ? null : `beklenen feralin-kmp/android, gelen: ${text}`),
      },
    ],
  });
  console.log(`kanıt: ${evidence}`);
  console.log("E2E kmp android emülatör (OkHttp): GEÇTİ (emülatör, gerçek cihaz değil)");
} catch (err) {
  exitCode = 1;
  console.error(`E2E kmp android emülatör: KALDI: ${err instanceof Error ? err.message : String(err)}`);
  if (collect) console.error(collect.logLines.join("").slice(-1500));
} finally {
  await device?.kill();
  collect?.child.kill();
}
process.exit(exitCode);
