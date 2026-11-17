// Olay üretimi: şema sınırları istemcide uygulanır, çünkü tek geçersiz alan toplayıcıda tüm batch'i 400 ile düşürür.
import { randomBytes } from "node:crypto";
import type { EventContext } from "./types.js";

export const MAX_PROPERTIES = 100;
export const MAX_IDENTIFIER_LENGTH = 128;
export const ATTRIBUTION_CLICK_PROPERTY = "fr_click";

const EVENT_NAME = /^[a-z][a-z0-9_]*$/;
const PROPERTY_KEY = /^[a-zA-Z][a-zA-Z0-9_]{0,63}$/;
const UTM_KEYS = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"];
const MAX_UTM_LENGTH = 256;
const ULID_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

export function validEventName(name: unknown): name is string {
  return typeof name === "string" && name.length > 0 && name.length <= 100 && EVENT_NAME.test(name);
}

/** Geçersiz anahtar ve serileştirilemeyen değer atılır; 100 anahtardan sonrası alınmaz. */
export function sanitizeProperties(properties: Record<string, unknown> | undefined): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (!properties || typeof properties !== "object") return out;
  let count = 0;
  for (const [key, value] of Object.entries(properties)) {
    if (count >= MAX_PROPERTIES) break;
    if (!PROPERTY_KEY.test(key)) continue;
    if (value === undefined || typeof value === "function" || typeof value === "symbol") continue;
    out[key] = value;
    count++;
  }
  return out;
}

function parseUrl(raw: unknown): URL | null {
  if (typeof raw !== "string") return null;
  try {
    const url = new URL(raw);
    return url.host ? url : null;
  } catch {
    return null;
  }
}

function clip(value: unknown, max: number): string | undefined {
  return typeof value === "string" && value.length > 0 ? value.slice(0, max) : undefined;
}

function nonNegativeInt(value: unknown): number | undefined {
  return typeof value === "number" && Number.isInteger(value) && value >= 0 ? value : undefined;
}

/** Bağlamı şemaya indirger. Bilinmeyen alan ve ayrıştırılamayan URL gönderilmez; sorgu dizgisi hiç çıkmaz. */
export function normalizeContext(context: EventContext | undefined): { context?: EventContext; utm: Record<string, string> } {
  const utm: Record<string, string> = {};
  if (!context || typeof context !== "object") return { utm };
  const out: EventContext = {};
  const page = parseUrl(context.page_url);
  if (page) {
    for (const key of UTM_KEYS) {
      const value = page.searchParams.get(key)?.trim();
      if (value) utm[key] = value.slice(0, MAX_UTM_LENGTH);
    }
    const clean = `${page.protocol}//${page.host}${page.pathname}`;
    if (clean.length <= 2048) out.page_url = clean;
  }
  const title = clip(context.page_title, 512);
  if (title) out.page_title = title;
  const referrer = parseUrl(context.referrer);
  if (referrer) out.referrer = `${referrer.protocol}//${referrer.host}`.slice(0, 2048);
  const locale = clip(context.locale, 16);
  if (locale) out.locale = locale;
  const timezone = clip(context.timezone, 64);
  if (timezone) out.timezone = timezone;
  if (context.screen && typeof context.screen === "object") {
    const width = nonNegativeInt(context.screen.width);
    const height = nonNegativeInt(context.screen.height);
    if (width !== undefined || height !== undefined) {
      out.screen = { ...(width !== undefined ? { width } : {}), ...(height !== undefined ? { height } : {}) };
    }
  }
  if (context.app && typeof context.app === "object") {
    const version = clip(context.app.version, 32);
    const build = clip(context.app.build, 32);
    if (version || build) out.app = { ...(version ? { version } : {}), ...(build ? { build } : {}) };
  }
  return Object.keys(out).length ? { context: out, utm } : { utm };
}

/** 26 karakter Crockford base32 ULID: 48 bit zaman + 80 bit güvenli rastgele. */
export function ulid(nowMs: number): string {
  let time = "";
  let remaining = Math.max(0, Math.floor(nowMs));
  for (let i = 0; i < 10; i++) {
    time = ULID_ALPHABET[remaining % 32] + time;
    remaining = Math.floor(remaining / 32);
  }
  const bytes = randomBytes(16);
  let random = "";
  for (let i = 0; i < 16; i++) random += ULID_ALPHABET[bytes[i]! % 32];
  return time + random;
}

/** FNV-1a 64 bit; Web, Android ve Flutter SDK'larıyla aynı değeri üretir. */
function fnv1a64(text: string): string {
  let hash = 0xcbf29ce484222325n;
  for (let i = 0; i < text.length; i++) {
    hash = BigInt.asUintN(64, (hash ^ BigInt(text.charCodeAt(i))) * 0x100000001b3n);
  }
  return hash.toString(16).padStart(16, "0");
}

/** Tüm event_id'lerin özeti + olay sayısı: sıradan bağımsız, aynı küme aynı anahtar, farklı içerik farklı anahtar. */
export function idempotencyKeyFor(eventIds: readonly string[]): string {
  const sorted = [...eventIds].sort();
  return `${fnv1a64(sorted.join(","))}-${sorted.length}`;
}
