#!/usr/bin/env node
// Uçtan uca: gerçek saas-api + gerçek services/mcp + PostgreSQL. Paket `npm pack` ile boş dizine kurulur, kurulu bin stdio
// üzerinden çalıştırılır ve tools/list gerçek MCP'den okunur. API anahtarı panelin kullandığı REST ucuyla üretilir.
//   MCP_E2E_DATABASE_URL='postgres://...' node packages/mcp-server/scripts/e2e-real-mcp.mjs
// Yalnız test veritabanı verin: otomatik migrasyon çalışır ve deneme kiracısı yazılır.
// FERALIN_E2E_FROM_REGISTRY=1: paket yerelde üretilmez, yayımlanmış `@feralin/mcp-server@<package.json sürümü>` npmjs.org'dan kurulur
// ve kilit dosyasından sürümü ve kaynağı denetlenir (temiz kurulum halkası).
import { spawn, spawnSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { createInterface } from "node:readline";
import { tmpdir } from "node:os";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const repo = join(root, "../..");
const database = process.env.MCP_E2E_DATABASE_URL;
const isWindows = process.platform === "win32";
const NPM_REGISTRY = "https://registry.npmjs.org/";
const fromRegistry = process.env.FERALIN_E2E_FROM_REGISTRY === "1";
if (!database) {
  console.error("HATA: MCP_E2E_DATABASE_URL zorunlu (yalnız test veritabanı)");
  process.exit(1);
}

const internalToken = randomBytes(32).toString("hex");
const npm = (args, cwd) => {
  console.log(`$ npm ${args.join(" ")}`);
  const [file, argv] = isWindows ? ["cmd.exe", ["/d", "/c", "npm", ...args]] : ["npm", args];
  const result = spawnSync(file, argv, { cwd, stdio: "inherit" });
  if (result.status !== 0) throw new Error(`npm ${args[0]} başarısız`);
};

function freePort() {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

function startTsx(cwd, env) {
  const log = [];
  const child = spawn(process.execPath, ["--import", "tsx", "src/main.ts"], { cwd, env: { ...process.env, ...env }, stdio: ["ignore", "pipe", "pipe"] });
  child.stdout.on("data", (d) => log.push(d.toString()));
  child.stderr.on("data", (d) => log.push(d.toString()));
  return { child, log };
}

async function waitHealthy(url, service, limitMs) {
  const started = Date.now();
  while (Date.now() - started < limitMs) {
    if (service.child.exitCode !== null) throw new Error(`süreç erken çıktı:\n${service.log.join("").slice(-2000)}`);
    try {
      if ((await fetch(url)).ok) return;
    } catch {
      // henüz açılmadı
    }
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  throw new Error(`${url} ${limitMs} ms içinde açılmadı:\n${service.log.join("").slice(-2000)}`);
}

async function createApiKey(apiBase) {
  const stamp = Date.now();
  const register = await fetch(`${apiBase}/v1/auth/register`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ email: `mcpstdio-${stamp}@example.test`, password: "integration-password-1", organization_name: `MCP stdio ${stamp}` }),
  });
  if (register.status !== 201) throw new Error(`kayıt başarısız: HTTP ${register.status}`);
  const session = /fr_session=([^;]+)/.exec(register.headers.get("set-cookie") ?? "")?.[1];
  if (!session) throw new Error("oturum çerezi yok");
  const organization = (await register.json()).organization.id;
  const created = await fetch(`${apiBase}/v1/developer/api-keys`, {
    method: "POST",
    headers: { authorization: `Bearer ${session}`, "content-type": "application/json" },
    body: JSON.stringify({ label: "mcp-stdio-e2e", scopes: ["workspace:read", "links:read"] }),
  });
  if (created.status !== 201) throw new Error(`anahtar üretilemedi: HTTP ${created.status}`);
  return { secret: (await created.json()).secret_once, organization };
}

/** Kurulu bin'i çalıştırır; JSON-RPC satırlarını stdio üzerinden konuşur. */
function startBridge(bin, env) {
  const child = spawn(process.execPath, [bin], { env: { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, ...env }, stdio: ["pipe", "pipe", "pipe"] });
  const pending = new Map();
  const stdoutLines = [];
  let stderr = "";
  child.stderr.on("data", (d) => (stderr += d));
  createInterface({ input: child.stdout }).on("line", (line) => {
    stdoutLines.push(line);
    const message = JSON.parse(line);
    pending.get(message.id)?.(message);
    pending.delete(message.id);
  });
  return {
    child,
    stdoutLines,
    stderr: () => stderr,
    notify: (message) => child.stdin.write(`${JSON.stringify(message)}\n`),
    request: (message) =>
      new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`yanıt gelmedi: ${message.method}`)), 30_000);
        pending.set(message.id, (reply) => {
          clearTimeout(timer);
          resolve(reply);
        });
        child.stdin.write(`${JSON.stringify(message)}\n`);
      }),
    close: () =>
      new Promise((resolve) => {
        child.once("exit", resolve);
        child.stdin.end();
      }),
  };
}

const INITIALIZE = { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "stdio-e2e", version: "1.0.0" } } };

const work = mkdtempSync(join(tmpdir(), "feralin-mcp-stdio-"));
let api;
let mcp;
let exitCode = 0;
const stop = async (service) => {
  if (!service || service.child.exitCode !== null) return;
  const exited = new Promise((resolve) => service.child.once("exit", resolve));
  service.child.kill();
  await exited;
};
try {
  const [apiPort, mcpPort] = await Promise.all([freePort(), freePort()]);
  const apiBase = `http://127.0.0.1:${apiPort}`;
  const mcpBase = `http://127.0.0.1:${mcpPort}`;
  api = startTsx(join(repo, "services/saas-api"), {
    NODE_ENV: "development",
    SAAS_API_HOST: "127.0.0.1",
    SAAS_API_PORT: String(apiPort),
    DATABASE_URL: database,
    SAAS_API_AUTO_MIGRATE: "true",
    SAAS_API_AUTH_RATE_LIMIT_PER_MINUTE: "1000",
    // Testler aynı adresten çok hesap açar: canlı kayıt ve kiracı tavanı burada yükseltilir (0046).
    SAAS_API_REGISTER_PER_IP_PER_HOUR: "100000",
    SAAS_API_REGISTER_GLOBAL_PER_MINUTE: "100000",
    SAAS_API_TENANT_MAX_PROJECTS: "10000",
    SAAS_API_TENANT_MAX_LINKS: "100000",
    LINK_PUBLIC_BASE_URL: "https://kisa.e2e.example",
    SAAS_API_INTERNAL_TOKEN: internalToken,
    SAAS_API_WEBHOOK_DISPATCHER: "false",
    ATTRIBUTION_JOB_ENABLED: "false",
  });
  await waitHealthy(`${apiBase}/v1/health`, api, 300_000);
  console.log("saas-api açıldı");
  mcp = startTsx(join(repo, "services/mcp"), {
    NODE_ENV: "test",
    MCP_HOST: "127.0.0.1",
    MCP_PORT: String(mcpPort),
    SAAS_API_URL: apiBase,
    MCP_AUTHORIZATION_SERVER_URL: apiBase,
    MCP_INTERNAL_TOKEN: internalToken,
    MCP_KILL_SWITCH_CACHE_SECONDS: "1",
  });
  await waitHealthy(`${mcpBase}/health`, mcp, 120_000);
  console.log("services/mcp açıldı");

  const consumer = join(work, "consumer");
  mkdirSync(consumer);
  writeFileSync(join(consumer, "package.json"), JSON.stringify({ name: "mcp-stdio-clean-install", private: true }));
  const manifest = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));
  if (fromRegistry) {
    // Yayımlanmış sürüm npmjs.org'dan kurulur; önbellek yerine registry'ye sorulur.
    const spec = `${manifest.name}@${manifest.version}`;
    console.log(`registry'den kurulacak: ${spec}`);
    npm(["install", "--no-audit", "--no-fund", "--registry", NPM_REGISTRY, "--prefer-online", spec], consumer);
  } else {
    const packDir = join(work, "pack");
    mkdirSync(packDir);
    npm(["pack", "--pack-destination", packDir], root);
    const tarball = join(packDir, readdirSync(packDir).find((name) => name.endsWith(".tgz")));
    console.log(`paket: ${basename(tarball)}`);
    npm(["install", "--no-audit", "--no-fund", tarball], consumer);
  }
  const lock = JSON.parse(readFileSync(join(consumer, "package-lock.json"), "utf8"));
  if (fromRegistry) {
    const entry = lock.packages?.[`node_modules/${manifest.name}`];
    if (!entry) throw new Error(`kurulmadı: ${manifest.name}`);
    if (entry.version !== manifest.version) throw new Error(`${manifest.name}: kurulan sürüm ${entry.version}, beklenen ${manifest.version}`);
    if (!String(entry.resolved ?? "").startsWith(NPM_REGISTRY)) throw new Error(`${manifest.name} registry'den gelmedi: ${entry.resolved}`);
    console.log(`registry kaynağı: ${entry.resolved} (${entry.integrity})`);
  }
  const installed = Object.keys(lock.packages).filter((name) => name.startsWith("node_modules/"));
  console.log(`kurulan paketler: ${installed.join(", ")}`);
  if (installed.length !== 1) throw new Error("çalışma zamanı bağımlılığı olmamalı");
  const bin = join(consumer, "node_modules/@feralin/mcp-server/dist/cli.js");

  const { secret, organization } = await createApiKey(apiBase);
  const bridge = startBridge(bin, { FERALIN_API_KEY: secret, FERALIN_MCP_URL: `${mcpBase}/mcp` });
  const init = await bridge.request(INITIALIZE);
  if (!init.result?.serverInfo) throw new Error(`initialize başarısız: ${JSON.stringify(init)}`);
  console.log(`  OK initialize: serverInfo=${JSON.stringify(init.result.serverInfo)} protokol=${init.result.protocolVersion}`);
  bridge.notify({ jsonrpc: "2.0", method: "notifications/initialized" });

  const list = await bridge.request({ jsonrpc: "2.0", id: 2, method: "tools/list" });
  const tools = (list.result?.tools ?? []).map((tool) => tool.name).sort();
  // propose_action yalnız `autopilot:propose` taşıyan kimliğe listelenir (F6-E03-T02); bu anahtarın kapsamı salt okunurdur.
  if (!tools.includes("list_workspaces") || tools.includes("propose_action")) throw new Error(`tools/list beklenmedik: ${JSON.stringify(list).slice(0, 500)}`);
  console.log(`  OK tools/list: ${tools.length} araç: ${tools.join(", ")}`);

  const call = await bridge.request({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "list_workspaces", arguments: {} } });
  const callText = JSON.stringify(call.result ?? call.error);
  if (call.result?.isError || !callText.includes(organization)) throw new Error(`list_workspaces kiracıyı döndürmedi: ${callText.slice(0, 500)}`);
  console.log("  OK tools/call list_workspaces: kiracı yalnız sunucu yanıtından");

  await bridge.close();
  if (bridge.stdoutLines.some((line) => line.includes(secret)) || bridge.stderr().includes(secret)) throw new Error("anahtar çıktıya sızdı");
  console.log(`  OK sır: stdout ${bridge.stdoutLines.length} satır, stderr ${bridge.stderr().length} bayt; anahtar yok, tüm stdout JSON-RPC`);

  // Yanlış anahtar: JSON-RPC hatası, süreç düşmez.
  const wrong = startBridge(bin, { FERALIN_API_KEY: `fak_live_${"0".repeat(64)}`, FERALIN_MCP_URL: `${mcpBase}/mcp` });
  const denied = await wrong.request(INITIALIZE);
  if (denied.error?.data?.http_status !== 401) throw new Error(`401 bekleniyordu: ${JSON.stringify(denied)}`);
  await wrong.close();
  console.log(`  OK yanlış anahtar: JSON-RPC hata kodu ${denied.error.code}, HTTP ${denied.error.data.http_status}`);
  console.log("E2E mcp-server: GEÇTİ");
} catch (err) {
  exitCode = 1;
  console.error(`E2E mcp-server: KALDI: ${err instanceof Error ? err.message : String(err)}`);
} finally {
  await stop(mcp);
  await stop(api);
  try {
    rmSync(work, { recursive: true, force: true, maxRetries: 3 });
  } catch {
    // Geçici dizin temizlenemezse testin sonucu değişmez.
  }
}
process.exit(exitCode);
