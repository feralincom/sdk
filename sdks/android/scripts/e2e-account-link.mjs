#!/usr/bin/env node
// Android SDK kurulum kimliği → gerçek services/saas-api `attribution/account-links` uçtan uca testi (şartname §31.2 yol 5, ADR-0007).
// Yerel saas-api'yi test veritabanına karşı açar, kayıt + Android projesi + `attribution:link` gizli anahtarı üretir, web tarafının hesap
// kanıtını yazar ve AccountLinkE2ETest'i (JVM) bu sunucuya karşı koşar. Üretim veritabanına bağlamayın: göçler uygulanır, deneme hesabı yazılır.
//   DATABASE_URL='postgres://...' node sdks/android/scripts/e2e-account-link.mjs
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const androidRoot = join(dirname(fileURLToPath(import.meta.url)), "..");
const repoRoot = join(androidRoot, "..", "..");
const apiRoot = join(repoRoot, "services", "saas-api");
const databaseUrl = process.env.DATABASE_URL;
if (!databaseUrl) {
  console.error("DATABASE_URL zorunlu (yalnız test veritabanı)");
  process.exit(2);
}
const port = process.env.FERALIN_E2E_API_PORT ?? "4793";
const base = `http://127.0.0.1:${port}`;
const stamp = Date.now();
const isWindows = process.platform === "win32";

function fail(message) {
  console.error(`KALDI: ${message}`);
  process.exitCode = 1;
  throw new Error(message);
}

async function call(method, path, { token, body } = {}) {
  const headers = { accept: "application/json" };
  if (token) headers.authorization = `Bearer ${token}`;
  if (body !== undefined) headers["content-type"] = "application/json";
  const res = await fetch(`${base}${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  const text = await res.text();
  let json = null;
  try {
    json = JSON.parse(text);
  } catch {
    // Problem gövdesi olmayan yanıt
  }
  return { status: res.status, json, headers: res.headers };
}

// tsx saas-api'nin geliştirme bağımlılığıdır (`pnpm install` sonrası services/saas-api/node_modules/tsx).
// Geliştirici makinesindeki olay deposu ve e-posta ayarları bu sürece taşınmaz; hesap eşleştirme yalnız PostgreSQL ister.
const serverEnv = { ...process.env };
for (const name of ["CLICKHOUSE_URL", "COLLECT_URL", "DATABASE_MIGRATION_URL", "SAAS_API_EMAIL_PROVIDER", "SAAS_API_REQUIRE_EMAIL_VERIFICATION"]) delete serverEnv[name];
const server = spawn(process.execPath, ["--import", "tsx", "src/main.ts"], {
  cwd: apiRoot,
  env: {
    ...serverEnv,
    NODE_ENV: "development",
    DATABASE_URL: databaseUrl,
    SAAS_API_AUTO_MIGRATE: "true",
    SAAS_API_PORT: port,
    SAAS_API_HOST: "127.0.0.1",
    SAAS_API_SECRET_KEY: randomBytes(32).toString("hex"),
    SAAS_API_COOKIE_SECURE: "false",
    SAAS_API_ALLOW_DEV_TOKENS: "false",
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let serverLog = "";
server.stdout.on("data", (chunk) => (serverLog += chunk));
server.stderr.on("data", (chunk) => (serverLog += chunk));

try {
  let ready = false;
  for (let i = 0; i < 240 && !ready; i++) {
    try {
      ready = (await fetch(`${base}/v1/health`)).ok;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
    if (server.exitCode !== null) break;
  }
  if (!ready) fail(`saas-api açılmadı\n${serverLog.slice(-2000)}`);
  console.log(`saas-api hazır: ${base}`);

  const email = `android-link-${stamp}@example.test`;
  const register = await call("POST", "/v1/auth/register", { body: { email, password: `Test-Parola-${stamp}`, organization_name: "Android E2E" } });
  if (register.status !== 201) fail(`kayıt ${register.status} ${JSON.stringify(register.json)}`);
  const cookie = register.headers.get("set-cookie") ?? "";
  const session = /fr_session=([^;]+)/.exec(cookie)?.[1];
  if (!session) fail("oturum çerezi yok");
  const project = await call("POST", "/v1/projects", { token: session, body: { name: "Android E2E", platform: "android" } });
  if (project.status !== 201) fail(`proje ${project.status} ${JSON.stringify(project.json)}`);
  const projectId = project.json.id;
  const key = await call("POST", "/v1/developer/api-keys", { token: session, body: { label: "musteri sunucusu", scopes: ["attribution:link"], project_id: projectId } });
  if (key.status !== 201) fail(`anahtar ${key.status} ${JSON.stringify(key.json)}`);
  const serverKey = key.json.secret_once;
  const accountRef = `acct-e2e-${stamp}`;
  // Web tarafı: kullanıcı web'de hesabına girdi (müşteri sunucusu bunu bildirir).
  const web = await call("POST", `/v1/projects/${projectId}/attribution/account-links`, { token: serverKey, body: { surface: "web", subject_id: `web-anon-${stamp}`, account_ref: accountRef, campaign: "android-e2e", consent: true } });
  if (web.status !== 200 || web.json?.linked !== false) fail(`web kanıtı ${web.status} ${JSON.stringify(web.json)}`);

  const gradle = isWindows ? ["cmd.exe", ["/d", "/c", join(androidRoot, "gradlew.bat")]] : [join(androidRoot, "gradlew"), []];
  const run = spawnSync(gradle[0], [...gradle[1], ":feralin:testDebugUnitTest", "--tests", "*AccountLinkE2ETest", "--rerun-tasks", "--console=plain", "-q"], {
    cwd: androidRoot,
    stdio: "inherit",
    env: { ...process.env, FERALIN_E2E_API_URL: base, FERALIN_E2E_SERVER_KEY: serverKey, FERALIN_E2E_PROJECT_ID: projectId, FERALIN_E2E_ACCOUNT_REF: accountRef },
  });
  const xml = join(androidRoot, "feralin", "build", "test-results", "testDebugUnitTest", "TEST-com.feralin.android.internal.AccountLinkE2ETest.xml");
  if (!existsSync(xml)) fail(`test sonucu yok (gradle çıkış ${run.status})`);
  const report = readFileSync(xml, "utf8");
  const attr = (name) => Number(new RegExp(`<testsuite[^>]* ${name}="(\\d+)"`).exec(report)?.[1] ?? NaN);
  const counts = { tests: attr("tests"), failures: attr("failures"), errors: attr("errors"), skipped: attr("skipped") };
  console.log(`AccountLinkE2ETest: tests=${counts.tests} failures=${counts.failures} errors=${counts.errors} skipped=${counts.skipped}`);
  for (const match of report.matchAll(/<testcase name="([^"]+)"[^>]*?(\/>|>([\s\S]*?)<\/testcase>)/g)) console.log(`  ${match[3]?.includes("<failure") || match[3]?.includes("<skipped") ? "KALDI" : "OK"} ${match[1]}`);
  if (run.status !== 0 || counts.tests !== 2 || counts.failures || counts.errors || counts.skipped) fail("AccountLinkE2ETest geçmedi");
  console.log("account-links e2e: GEÇTİ");
} finally {
  server.kill();
}
