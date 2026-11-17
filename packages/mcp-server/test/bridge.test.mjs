// Birim testleri: sahte HTTP ile köprü davranışı. Gerçek services/mcp testi scripts/e2e-real-mcp.mjs içindedir.
import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { PassThrough } from "node:stream";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { ConfigError, StdioBridge, resolveConfig } from "../dist/bridge.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const TOKEN = "fak_test_gizli_anahtar_0001";
const URL_BASE = "https://mcp.example.test/mcp";

function json(body, init = {}) {
  return new Response(JSON.stringify(body), { status: 200, headers: { "content-type": "application/json" }, ...init });
}

/** Köprüyü sahte fetch ile çalıştırır: mesajlar sırayla verilir, stdin kapanınca çıktı satırları döner. */
async function drive(messages, respond) {
  const input = new PassThrough();
  const output = new PassThrough();
  const calls = [];
  const logs = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return respond({ url, init, body: init.body ? JSON.parse(init.body) : undefined });
  };
  const bridge = new StdioBridge({ url: URL_BASE, token: TOKEN, input, output, fetch: fetchImpl, log: (m) => logs.push(m) });
  const lines = [];
  output.on("data", (chunk) => lines.push(...chunk.toString().split("\n").filter(Boolean)));
  const running = bridge.run();
  for (const message of messages) input.write(`${typeof message === "string" ? message : JSON.stringify(message)}\n`);
  input.end();
  await running;
  return { calls, logs, out: lines.map((line) => JSON.parse(line)), raw: lines.join("\n") };
}

const INIT = { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "t", version: "1" } } };
const LIST = { jsonrpc: "2.0", id: 2, method: "tools/list" };
const initResult = { jsonrpc: "2.0", id: 1, result: { protocolVersion: "2025-06-18", capabilities: {}, serverInfo: { name: "feralin", version: "x" } } };

test("anahtar yalnız ortamdan: komut satırı reddedilir, pk_ ve eksik anahtar reddedilir", () => {
  assert.throws(() => resolveConfig({}, []), ConfigError);
  assert.throws(() => resolveConfig({ FERALIN_API_KEY: "pk_live_abc" }, []), /pk_/);
  assert.throws(() => resolveConfig({ FERALIN_API_KEY: TOKEN }, ["--token", "x"]), /komut satırından/);
  assert.throws(() => resolveConfig({ FERALIN_API_KEY: TOKEN }, ["--api-key=x"]), /komut satırından/);
  assert.equal(resolveConfig({ FERALIN_API_KEY: ` ${TOKEN} ` }, []).token, TOKEN);
});

test("adres: https zorunlu, http yalnız yerelde; kullanıcı bilgisi reddedilir", () => {
  const key = { FERALIN_API_KEY: TOKEN };
  assert.equal(resolveConfig(key, []).url, "https://feralin.com/mcp");
  assert.throws(() => resolveConfig({ ...key, FERALIN_MCP_URL: "http://feralin.com/mcp" }, []), /https/);
  assert.throws(() => resolveConfig({ ...key, FERALIN_MCP_URL: "ftp://x" }, []), /https/);
  assert.throws(() => resolveConfig({ ...key, FERALIN_MCP_URL: "https://a:b@feralin.com/mcp" }, []), /kullanıcı/);
  assert.equal(resolveConfig({ ...key, FERALIN_MCP_URL: "http://127.0.0.1:8382/mcp" }, []).url, "http://127.0.0.1:8382/mcp");
  assert.equal(resolveConfig({ ...key, FERALIN_MCP_URL: "http://localhost:8382/mcp" }, []).url, "http://localhost:8382/mcp");
});

test("oturum başlığı ve protokol sürümü initialize yanıtından alınır, sonraki isteklere gider", async () => {
  const { calls, out } = await drive([INIT, { jsonrpc: "2.0", method: "notifications/initialized" }, LIST], ({ body, init }) => {
    if (init.method === "DELETE") return new Response(null, { status: 204 });
    if (body.method === "initialize") return json(initResult, { headers: { "content-type": "application/json", "mcp-session-id": "sess-1" } });
    if (body.method === "notifications/initialized") return new Response(null, { status: 202 });
    return json({ jsonrpc: "2.0", id: 2, result: { tools: [{ name: "list_workspaces" }] } });
  });
  assert.equal(calls[0].init.headers.authorization, `Bearer ${TOKEN}`);
  assert.equal(calls[0].init.headers["mcp-session-id"], undefined);
  const list = calls.find((c) => c.init.body?.includes("tools/list"));
  assert.equal(list.init.headers["mcp-session-id"], "sess-1");
  assert.equal(list.init.headers["mcp-protocol-version"], "2025-06-18");
  assert.deepEqual(out.map((m) => m.id).sort(), [1, 2]);
  const del = calls.at(-1);
  assert.equal(del.init.method, "DELETE");
  assert.equal(del.init.headers["mcp-session-id"], "sess-1");
});

test("sonraki istekler initialize tamamlanmadan gönderilmez", async () => {
  const order = [];
  let release;
  const gate = new Promise((resolve) => (release = resolve));
  const { out } = await drive([INIT, LIST], async ({ body, init }) => {
    if (init.method === "DELETE") return new Response(null, { status: 204 });
    order.push(body.method);
    if (body.method === "initialize") {
      setTimeout(release, 20);
      await gate;
      order.push("initialize-bitti");
      return json(initResult, { headers: { "content-type": "application/json", "mcp-session-id": "s" } });
    }
    return json({ jsonrpc: "2.0", id: 2, result: { tools: [] } });
  });
  assert.deepEqual(order, ["initialize", "initialize-bitti", "tools/list"]);
  assert.equal(out.length, 2);
});

test("SSE yanıtı satırlara çevrilir", async () => {
  const sse = `event: message\ndata: ${JSON.stringify({ jsonrpc: "2.0", method: "notifications/progress", params: {} })}\n\ndata: ${JSON.stringify({ jsonrpc: "2.0", id: 2, result: { tools: [] } })}\n\n`;
  const { out } = await drive([LIST], ({ init }) => {
    if (init.method === "DELETE") return new Response(null, { status: 204 });
    return new Response(sse, { status: 200, headers: { "content-type": "text/event-stream" } });
  });
  assert.equal(out[0].method, "notifications/progress");
  assert.equal(out[1].id, 2);
});

test("HTTP hatası JSON-RPC hatasına çevrilir: yalnız güvenli alanlar, anahtar yok", async () => {
  const problem = { type: "urn:feralin:problem:mcp_invalid_token", status: 401, detail: "Token geçersiz.", trace_id: "t1", ic_ayrinti: "sizmamali" };
  const { out, raw, logs } = await drive([{ jsonrpc: "2.0", id: 9, method: "tools/list" }], ({ init }) => {
    if (init.method === "DELETE") return new Response(null, { status: 204 });
    return new Response(JSON.stringify(problem), { status: 401, headers: { "content-type": "application/problem+json" } });
  });
  assert.equal(out[0].id, 9);
  assert.equal(out[0].error.code, -32000);
  assert.equal(out[0].error.message, "Token geçersiz.");
  assert.equal(out[0].error.data.http_status, 401);
  assert.equal(out[0].error.data.trace_id, "t1");
  assert.ok(!raw.includes("sizmamali"));
  assert.ok(!raw.includes(TOKEN));
  assert.ok(!logs.join("\n").includes(TOKEN));
});

test("ağ hatası isteğe hata döner, bildirime dönmez; süreç düşmez", async () => {
  const { out, logs } = await drive([{ jsonrpc: "2.0", id: 3, method: "tools/list" }, { jsonrpc: "2.0", method: "notifications/x" }], () => {
    throw new TypeError(`bağlantı reddedildi ${TOKEN}`);
  });
  assert.equal(out.length, 1);
  assert.equal(out[0].id, 3);
  assert.ok(!logs.join("\n").includes(TOKEN), "hata mesajı loga yazılmaz");
});

test("geçersiz JSON parse hatası verir, sonraki mesaj çalışır", async () => {
  const { out } = await drive(["{bozuk", { jsonrpc: "2.0", id: 4, method: "tools/list" }], ({ init }) => {
    if (init.method === "DELETE") return new Response(null, { status: 204 });
    return json({ jsonrpc: "2.0", id: 4, result: {} });
  });
  const parseError = out.find((m) => m.error);
  assert.equal(parseError.error.code, -32700);
  assert.equal(parseError.id, null);
  assert.ok(out.some((m) => m.id === 4));
});

test("süresi dolan oturum (404) sonraki isteklerde eski kimliği taşımaz", async () => {
  let listCalls = 0;
  const { calls } = await drive([INIT, LIST, { jsonrpc: "2.0", id: 3, method: "tools/list" }], ({ body, init }) => {
    if (init.method === "DELETE") return new Response(null, { status: 204 });
    if (body.method === "initialize") return json(initResult, { headers: { "content-type": "application/json", "mcp-session-id": "s1" } });
    listCalls += 1;
    return new Response("{}", { status: 404, headers: { "content-type": "application/problem+json" } });
  });
  assert.equal(listCalls, 2);
  assert.equal(calls.filter((c) => c.init.method === "DELETE").length, 0, "oturum zaten yok, DELETE gönderilmez");
});

test("CLI: anahtar yoksa stdout boş kalır, stderr açıklar, çıkış 1; argümanla anahtar reddedilir", async () => {
  const run = (args, env) =>
    new Promise((resolve) => {
      const child = spawn(process.execPath, [join(root, "dist/cli.js"), ...args], { env: { PATH: process.env.PATH, ...env }, stdio: ["ignore", "pipe", "pipe"] });
      let stdout = "";
      let stderr = "";
      child.stdout.on("data", (d) => (stdout += d));
      child.stderr.on("data", (d) => (stderr += d));
      child.on("exit", (code) => resolve({ code, stdout, stderr }));
    });
  const missing = await run([], {});
  assert.equal(missing.code, 1);
  assert.equal(missing.stdout, "");
  assert.match(missing.stderr, /FERALIN_API_KEY/);
  const viaArg = await run(["--token", "gizli_deger"], { FERALIN_API_KEY: TOKEN });
  assert.equal(viaArg.code, 1);
  assert.ok(!viaArg.stderr.includes("gizli_deger"));
  assert.ok(!viaArg.stderr.includes(TOKEN));
});
