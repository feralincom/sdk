// `fr_error` sözleşmesi (X4): Web (`@feralin/web/errors`), Android (`ErrorEvent.kt`) ve React Native SDK'larıyla aynı kurallar.
// Ham yığın izi, dizin yolu, URL ve kullanıcı verisi GİTMEZ. Yalnız hata sınıfı adı, temizlenmiş kısa mesaj, normalize edilmiş
// çerçevelerin özeti olan parmak izi, en üst çerçeve ve isteğe bağlı sembolleştirme konumları (dosya taban adı, satır, sütun, işlev
// adı) gider. Toplayıcı (`services/collect/internal/httpapi/error_adrevenue_filter.go`) mesajı ve çerçeveleri ayrıca temizler.

export const ERROR_EVENT_NAME = "fr_error";

export type ErrorOrigin = "window_onerror" | "unhandledrejection" | "uncaught_exception" | "handled" | "manual";
export const ERROR_ORIGINS: readonly ErrorOrigin[] = ["window_onerror", "unhandledrejection", "uncaught_exception", "handled", "manual"];

export const ERROR_MAX_MESSAGE = 200;
const MAX_TYPE = 64;
const MAX_FRAME = 160;
const MAX_FUNCTION = 60;
const FINGERPRINT_FRAMES = 5;
const MAX_STACK_LINES = 50;
const MAX_POSITIONS = 5;
const MAX_POSITION_VALUE = 10_000_000;
// Toplayıcının `frames[].file` kuralı: yalnız taban ad; dizin, şema ve sorgu yok.
const FILE_BASENAME = /^[A-Za-z0-9._~-]{1,128}$/;

/** Sembolleştirme konumu: dosya taban adı, 1 tabanlı satır ve sütun, isteğe bağlı işlev adı. */
export interface SourcePosition {
  file: string;
  line: number;
  column: number;
  function?: string;
}

export interface ErrorProperties {
  error_type: string;
  message?: string;
  fingerprint: string;
  top_frame?: string;
  frame_count: number;
  app_version?: string;
  frames?: SourcePosition[];
  handled: boolean;
  fatal: boolean;
  origin: ErrorOrigin;
}

/** FNV-1a 64 bit (Web, Android ve Flutter SDK'larıyla aynı özet): 16 küçük harf onaltılı. */
export function fnv1a64(text: string): string {
  let hash = 0xcbf29ce484222325n;
  for (let i = 0; i < text.length; i++) hash = BigInt.asUintN(64, (hash ^ BigInt(text.charCodeAt(i))) * 0x100000001b3n);
  return hash.toString(16).padStart(16, "0");
}

/** Mesajdan URL, e-posta, UUID, uzun belirteç ve uzun sayıları çıkarır; sıra toplayıcıyla aynıdır. 200 karaktere kırpar. */
export function scrubErrorMessage(message: string): string {
  return message
    .replace(/\b[a-z][a-z0-9+.-]*:\/\/[^\s"'<>]+/gi, "[url]")
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "[email]")
    .replace(/\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/gi, "[id]")
    .replace(/\b[A-Za-z0-9_\-+/=]{24,}\b/g, (m) => (/\d/.test(m) ? "[token]" : m))
    .replace(/\+?\d[\d\s\-().]{5,}\d/g, (m) => (m.replace(/\D/g, "").length >= 7 ? "[num]" : m))
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, ERROR_MAX_MESSAGE);
}

/** Dosya yolunu kararlı kısa ada indirir: sorgu, parça ve derleme özeti çıkar (`app.3f9a1b2c.js` → `app.js`), dizin gitmez. */
export function normalizeFile(location: string): string {
  const cleaned = (location.split("#")[0] ?? "").split("?")[0] ?? "";
  const base = cleaned.split(/[\\/]/).filter(Boolean).pop() ?? "";
  return base.replace(/[.-][0-9a-f]{6,}(?=\.|$)/gi, "").slice(0, 80) || "unknown";
}

interface RawFrame {
  fn: string;
  loc: string;
}

/** V8 (`at fn (dosya:1:2)`, `at dosya:1:2`) ve JavaScriptCore/SpiderMonkey (`fn@dosya:1:2`) satırlarını okur. */
function parseLines(stack: unknown): RawFrame[] {
  if (typeof stack !== "string" || stack === "") return [];
  const out: RawFrame[] = [];
  for (const raw of stack.split("\n").slice(0, MAX_STACK_LINES)) {
    const line = raw.trim();
    if (line.startsWith("at ")) {
      const m = /^at\s+(?:(.*?)\s+\()?(.*?)\)?$/.exec(line);
      if (m) out.push({ fn: m[1] ?? "", loc: m[2] ?? "" });
    } else if (line.includes("@")) {
      const at = line.lastIndexOf("@");
      out.push({ fn: line.slice(0, at), loc: line.slice(at + 1) });
    }
  }
  return out;
}

function cleanFunction(fn: string): string {
  // `new Foo`, `async fn`, `Object.fn [as alias]` gibi önekler ve takma adlar atılır.
  return fn.replace(/^(?:async|new)\s+/, "").replace(/\s*\[as [^\]]*\]$/, "").trim().slice(0, MAX_FUNCTION);
}

/** Node'un kendi çerçeveleri (`node:internal/...`, `internal/...`) uygulama çerçevesi varken parmak izine girmez (Android çerçeve süzgeci gibi). */
function isRuntimeFrame(loc: string): boolean {
  return loc.startsWith("node:") || loc.startsWith("internal/") || loc === "native" || loc === "<anonymous>";
}

/**
 * Yığın izini normalize çerçevelere çevirir (`işlev@dosya`). Satır, sütun ve dizin atılır: kod biraz kaydığında da aynı hata aynı
 * parmak izini üretir. Uygulama çerçevesi varsa Node çalışma zamanı çerçeveleri atlanır.
 */
export function normalizeFrames(stack: unknown): string[] {
  const parsed = parseLines(stack).map((f) => ({ ...f, loc: f.loc.replace(/(?::\d+){1,2}$/, "") }));
  const app = parsed.filter((f) => !isRuntimeFrame(f.loc));
  return (app.length > 0 ? app : parsed).map((f) => `${cleanFunction(f.fn) || "<anonymous>"}@${f.loc ? normalizeFile(f.loc) : "unknown"}`);
}

/** En üst beş uygulama çerçevesinin konumu; dosya yalnız taban adıyla gider. Satırı olmayan ya da adı güvenli karakter dışı çerçeve atlanır. */
export function sourcePositions(stack: unknown): SourcePosition[] {
  const out: SourcePosition[] = [];
  for (const { fn, loc } of parseLines(stack)) {
    if (out.length >= MAX_POSITIONS) break;
    if (isRuntimeFrame(loc)) continue;
    const pos = /:(\d+):(\d+)$/.exec(loc);
    if (!pos) continue;
    const file = (loc.slice(0, pos.index).split("#")[0] ?? "").split("?")[0]?.split(/[\\/]/).filter(Boolean).pop() ?? "";
    const line = Number(pos[1]);
    const column = Number(pos[2]);
    if (!FILE_BASENAME.test(file) || line < 1 || line > MAX_POSITION_VALUE || column < 0 || column > MAX_POSITION_VALUE) continue;
    const name = cleanFunction(fn);
    out.push(name ? { file, line, column, function: name } : { file, line, column });
  }
  return out;
}

function typeNameOf(error: unknown): string {
  if (error && typeof error === "object") {
    const e = error as { name?: unknown; constructor?: { name?: unknown } };
    if (typeof e.name === "string" && e.name) return e.name.slice(0, MAX_TYPE);
    if (typeof e.constructor?.name === "string" && e.constructor.name && e.constructor.name !== "Object") return e.constructor.name.slice(0, MAX_TYPE);
  }
  return "Error";
}

export interface BuildErrorOptions {
  /** Uygulama sürümü; 32 karakteri aşarsa gönderilmez. */
  appVersion?: string;
  /** Sembolleştirme konumları (`frames`) gönderilsin mi; varsayılan true. */
  sourcePositions?: boolean;
  /** Ölümcül hata mı; yalnız `uncaught_exception` kökeninde anlamlıdır. Varsayılan false. */
  fatal?: boolean;
}

/**
 * Hata gövdesini sözleşmeye göre kurar (packages/schemas/utp/v1/event.schema.json, `fr_error`). Parmak izi hata türü ve en üst
 * beş çerçevenin özetidir; çerçeve yoksa türün yanına rakamsız mesaj girer.
 */
export function buildErrorProperties(error: unknown, origin: ErrorOrigin, options: BuildErrorOptions = {}): ErrorProperties {
  let errorType = typeNameOf(error);
  let rawMessage = "";
  let stack: unknown;
  if (error && typeof error === "object") {
    const e = error as { message?: unknown; stack?: unknown };
    rawMessage = typeof e.message === "string" ? e.message : "";
    stack = e.stack;
  } else if (typeof error === "string") {
    rawMessage = error;
    errorType = "Error";
  } else if (error !== undefined && error !== null) {
    rawMessage = String(error);
  }
  const frames = normalizeFrames(stack);
  const message = scrubErrorMessage(rawMessage);
  const basis = frames.length > 0 ? frames.slice(0, FINGERPRINT_FRAMES).join("|") : message.replace(/\d+/g, "#");
  const props: ErrorProperties = {
    error_type: errorType,
    fingerprint: fnv1a64(`${errorType}|${basis}`),
    frame_count: Math.min(frames.length, 1000),
    handled: origin === "handled" || origin === "manual",
    fatal: options.fatal === true,
    origin,
  };
  if (message) props.message = message;
  if (frames[0]) props.top_frame = frames[0].slice(0, MAX_FRAME);
  if (typeof options.appVersion === "string" && options.appVersion && options.appVersion.length <= 32) props.app_version = options.appVersion;
  if (options.sourcePositions !== false) {
    const positions = sourcePositions(stack);
    if (positions.length > 0) props.frames = positions;
  }
  return props;
}

export interface ErrorLimiterOptions {
  /** Örnekleme oranı 0..1 (varsayılan 1). */
  sampleRate?: number;
  /** Pencere başına en çok olay (varsayılan 20). */
  maxEvents?: number;
  /** Pencere başına aynı parmak izi için en çok olay (varsayılan 3). */
  maxPerFingerprint?: number;
  /**
   * Sayaçların sıfırlandığı süre (ms). Mobil SDK'larda sınır süreç ömrü boyuncadır; sunucu süreci günlerce çalıştığı için
   * varsayılan bir saattir. 0 süreç ömrü demektir.
   */
  windowMs?: number;
}

/** Hata fırtınası sınırı: toplayıcıyı ve kotayı aynı hatanın binlerce kopyasıyla doldurmaz. */
export class ErrorLimiter {
  private total = 0;
  private readonly perFingerprint = new Map<string, number>();
  private windowStart: number;
  private readonly sampleRate: number;
  private readonly maxEvents: number;
  private readonly maxPerFingerprint: number;
  private readonly windowMs: number;

  constructor(
    options: ErrorLimiterOptions = {},
    private readonly now: () => number = Date.now,
    private readonly random: () => number = Math.random,
  ) {
    this.sampleRate = Math.min(1, Math.max(0, Number.isFinite(options.sampleRate) ? (options.sampleRate as number) : 1));
    this.maxEvents = Math.max(0, Math.floor(options.maxEvents ?? 20));
    this.maxPerFingerprint = Math.max(1, Math.floor(options.maxPerFingerprint ?? 3));
    this.windowMs = Math.max(0, options.windowMs ?? 3_600_000);
    this.windowStart = now();
  }

  allow(fingerprint: string): boolean {
    if (this.windowMs > 0 && this.now() - this.windowStart >= this.windowMs) {
      this.total = 0;
      this.perFingerprint.clear();
      this.windowStart = this.now();
    }
    if (this.total >= this.maxEvents) return false;
    if (this.sampleRate < 1 && this.random() >= this.sampleRate) return false;
    const seen = this.perFingerprint.get(fingerprint) ?? 0;
    if (seen >= this.maxPerFingerprint) return false;
    this.perFingerprint.set(fingerprint, seen + 1);
    this.total++;
    return true;
  }
}
