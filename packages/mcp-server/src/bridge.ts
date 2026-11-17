// stdio ↔ Streamable HTTP köprüsü. MCP içeriğini yorumlamaz, JSON-RPC mesajlarını olduğu gibi taşır: araç kararları, yetki ve
// kiracı sınırı sunucudadır. Veritabanı ve kalıcı durum yoktur; anahtar yalnız Authorization başlığında gider. stdout yalnız
// protokol içindir, tüm günlük stderr'e yazılır ve anahtar veya mesaj içeriği taşımaz.
import { createInterface } from "node:readline";
import type { Readable, Writable } from "node:stream";

export const BRIDGE_VERSION = "0.1.0";
export const DEFAULT_URL = "https://feralin.com/mcp";

// Sunucu gövdeyi 256 KB ile sınırlar; bu sınır yalnız bellek güvenliği içindir, reddi sunucu verir.
const MAX_LINE_BYTES = 4 * 1024 * 1024;
const REQUEST_TIMEOUT_MS = 120_000;
const JSON_RPC_INTERNAL = -32603;
const JSON_RPC_PARSE = -32700;
const UPSTREAM_ERROR = -32000;

export interface BridgeOptions {
  url: string;
  token: string;
  input: Readable;
  output: Writable;
  log?: (message: string) => void;
  fetch?: typeof fetch;
  timeoutMs?: number;
}

/** Yapılandırma hatası; süreç stdout'a hiçbir şey yazmadan çıkar. */
export class ConfigError extends Error {}

export function resolveConfig(env: Record<string, string | undefined>, argv: readonly string[]): { url: string; token: string } {
  for (const arg of argv) {
    // Anahtar komut satırında süreç listesine ve kabuk geçmişine düşerdi.
    if (/^--?(token|key|api-key|api_key|secret|authorization)\b/i.test(arg)) {
      throw new ConfigError("anahtar komut satırından verilemez; FERALIN_API_KEY ortam değişkenini kullanın");
    }
  }
  const token = (env.FERALIN_API_KEY ?? "").trim();
  if (!token) throw new ConfigError("FERALIN_API_KEY ortam değişkeni zorunlu");
  if (/\s/.test(token)) throw new ConfigError("FERALIN_API_KEY boşluk içeremez");
  if (token.startsWith("pk_")) throw new ConfigError("proje anahtarı (pk_) yalnız olay gönderir; Feralin API anahtarı (fak_) verin");
  const raw = (env.FERALIN_MCP_URL ?? DEFAULT_URL).trim();
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new ConfigError("FERALIN_MCP_URL geçerli bir adres değil");
  }
  const loopback = url.hostname === "127.0.0.1" || url.hostname === "localhost" || url.hostname === "[::1]";
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new ConfigError("FERALIN_MCP_URL https olmalı; http yalnız yerel adreste kabul edilir");
  }
  if (url.username || url.password) throw new ConfigError("FERALIN_MCP_URL kullanıcı bilgisi içeremez");
  return { url: url.toString(), token };
}

type JsonRpcId = string | number | null;

interface JsonRpcMessage {
  jsonrpc?: string;
  id?: JsonRpcId;
  method?: string;
  result?: { protocolVersion?: unknown };
}

function errorResponse(id: JsonRpcId, code: number, message: string, data?: Record<string, unknown>): string {
  return JSON.stringify({ jsonrpc: "2.0", id, error: { code, message, ...(data ? { data } : {}) } });
}

/** Sunucunun RFC 7807 gövdesinden yalnız güvenli alanlar; ham yanıt istemciye aktarılmaz. */
function problemSummary(text: string): { message: string; data: Record<string, unknown> } {
  try {
    const parsed = JSON.parse(text) as Record<string, unknown>;
    const data: Record<string, unknown> = {};
    for (const field of ["type", "status", "trace_id", "retry_after_seconds", "kill_switch_scope", "required_scopes"]) {
      if (parsed[field] !== undefined) data[field] = parsed[field];
    }
    const detail = typeof parsed.detail === "string" ? parsed.detail : "";
    return { message: detail.slice(0, 300), data };
  } catch {
    return { message: "", data: {} };
  }
}

/** text/event-stream gövdesindeki data satırlarını sırayla verir. */
async function* readSse(body: ReadableStream<Uint8Array>): AsyncGenerator<string> {
  const decoder = new TextDecoder();
  const reader = body.getReader();
  let buffer = "";
  let data: string[] = [];
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (value) buffer += decoder.decode(value, { stream: true });
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const line = buffer.slice(0, newline).replace(/\r$/, "");
        buffer = buffer.slice(newline + 1);
        if (line === "") {
          if (data.length) yield data.join("\n");
          data = [];
        } else if (line.startsWith("data:")) {
          data.push(line.slice(5).replace(/^ /, ""));
        }
        newline = buffer.indexOf("\n");
      }
      if (done) break;
    }
    if (data.length) yield data.join("\n");
  } finally {
    reader.releaseLock();
  }
}

export class StdioBridge {
  private readonly url: string;
  private readonly token: string;
  private readonly input: Readable;
  private readonly output: Writable;
  private readonly log: (message: string) => void;
  private readonly fetchImpl: typeof fetch;
  private readonly timeoutMs: number;
  private sessionId: string | null = null;
  private protocolVersion: string | null = null;
  /** initialize yanıtı gelmeden sonraki istekler gönderilmez: oturum kimliği henüz yoktur. */
  private initializing: Promise<void> | null = null;
  private notifications: Promise<void> = Promise.resolve();
  private readonly inflight = new Set<Promise<void>>();

  constructor(options: BridgeOptions) {
    this.url = options.url;
    this.token = options.token;
    this.input = options.input;
    this.output = options.output;
    this.log = options.log ?? (() => {});
    this.fetchImpl = options.fetch ?? globalThis.fetch;
    this.timeoutMs = options.timeoutMs ?? REQUEST_TIMEOUT_MS;
  }

  /** stdin kapanana kadar çalışır, sonra oturumu kapatır. */
  async run(): Promise<void> {
    const lines = createInterface({ input: this.input, crlfDelay: Infinity });
    for await (const line of lines) {
      if (line.trim() === "") continue;
      this.track(this.handleLine(line));
    }
    await Promise.allSettled([...this.inflight]);
    await this.shutdown();
  }

  private track(work: Promise<void>): void {
    const guarded = work.catch((err: unknown) => {
      this.log(`beklenmeyen köprü hatası: ${err instanceof Error ? err.name : "unknown"}`);
    });
    this.inflight.add(guarded);
    void guarded.finally(() => this.inflight.delete(guarded));
  }

  private async handleLine(line: string): Promise<void> {
    if (Buffer.byteLength(line) > MAX_LINE_BYTES) {
      this.write(errorResponse(null, JSON_RPC_PARSE, "mesaj köprünün boyut sınırını aşıyor"));
      return;
    }
    let message: JsonRpcMessage | JsonRpcMessage[];
    try {
      message = JSON.parse(line) as JsonRpcMessage | JsonRpcMessage[];
    } catch {
      this.write(errorResponse(null, JSON_RPC_PARSE, "geçersiz JSON"));
      return;
    }
    const single = Array.isArray(message) ? null : message;
    if (single?.method === "initialize") {
      const work = this.forward(line, single);
      this.initializing = work.catch(() => undefined);
      await work;
      return;
    }
    if (this.initializing) await this.initializing;
    // Bildirimler kendi aralarında ve sonraki isteklere göre sıralı gider (notifications/initialized önce ulaşmalı);
    // istekler birbirini beklemez, uzun süren araç çağrısı iptal bildirimini tutmaz.
    if (single && single.id === undefined) {
      const work = this.notifications.then(() => this.forward(line, single));
      this.notifications = work.catch(() => undefined);
      await work;
      return;
    }
    await this.notifications;
    await this.forward(line, single);
  }

  private headers(): Record<string, string> {
    const headers: Record<string, string> = {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
      authorization: `Bearer ${this.token}`,
      "user-agent": `feralin-mcp-server/${BRIDGE_VERSION}`,
    };
    if (this.sessionId) headers["mcp-session-id"] = this.sessionId;
    if (this.protocolVersion) headers["mcp-protocol-version"] = this.protocolVersion;
    return headers;
  }

  private async forward(body: string, message: JsonRpcMessage | null): Promise<void> {
    const id = message?.id ?? null;
    const isRequest = message !== null && message.id !== undefined && message.method !== undefined;
    let response: Response;
    try {
      response = await this.fetchImpl(this.url, {
        method: "POST",
        headers: this.headers(),
        body,
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (err) {
      this.log(`sunucuya ulaşılamadı: ${err instanceof Error ? err.name : "unknown"}`);
      if (isRequest) this.write(errorResponse(id, UPSTREAM_ERROR, "Feralin MCP sunucusuna ulaşılamadı"));
      return;
    }

    const session = response.headers.get("mcp-session-id");
    if (session && message?.method === "initialize") this.sessionId = session;

    // Bildirim ve yanıt iletileri gövdesiz kabul edilir.
    if (response.status === 202 || response.status === 204) return;

    const type = response.headers.get("content-type") ?? "";
    if (!response.ok) {
      const summary = problemSummary(await response.text().catch(() => ""));
      this.log(`sunucu reddetti: HTTP ${response.status}`);
      // Süresi dolan oturumda istemci yeniden initialize etmelidir; eski kimlik tutulmaz.
      if (response.status === 404) {
        this.sessionId = null;
        this.protocolVersion = null;
      }
      if (isRequest) this.write(errorResponse(id, UPSTREAM_ERROR, summary.message || `Feralin MCP sunucusu HTTP ${response.status} döndürdü`, { http_status: response.status, ...summary.data }));
      return;
    }
    if (type.includes("text/event-stream") && response.body) {
      for await (const data of readSse(response.body)) this.deliver(data, message);
      return;
    }
    const text = await response.text();
    if (text.trim()) this.deliver(text, message);
  }

  /** Sunucu mesajı satır olarak yazılır; initialize yanıtından protokol sürümü alınır. */
  private deliver(text: string, request: JsonRpcMessage | null): void {
    let compact: string;
    try {
      const parsed = JSON.parse(text) as JsonRpcMessage;
      if (request?.method === "initialize" && typeof parsed.result?.protocolVersion === "string") {
        this.protocolVersion = parsed.result.protocolVersion;
      }
      compact = JSON.stringify(parsed);
    } catch {
      this.log("sunucudan geçersiz JSON");
      if (request?.id !== undefined) this.write(errorResponse(request.id, JSON_RPC_INTERNAL, "sunucu yanıtı çözülemedi"));
      return;
    }
    this.write(compact);
  }

  private write(line: string): void {
    this.output.write(`${line}\n`);
  }

  private async shutdown(): Promise<void> {
    if (!this.sessionId) return;
    try {
      await this.fetchImpl(this.url, { method: "DELETE", headers: this.headers(), signal: AbortSignal.timeout(5_000) });
    } catch (err) {
      this.log(`oturum kapatılamadı: ${err instanceof Error ? err.name : "unknown"}`);
    }
    this.sessionId = null;
  }
}
