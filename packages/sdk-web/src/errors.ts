// Feralin Web SDK — hata yakalama modülü (X4, ayrı giriş noktası, çekirdek bütçesine girmez).
// `window.onerror` (error olayı) ve `unhandledrejection` dinlenir; her hata `fr_error` olayına çevrilir. Veri modeli: ham yığın izi,
// URL, sayfa içeriği ve kullanıcı bilgisi GİTMEZ. Yalnız hata sınıfı adı, temizlenmiş kısa mesaj, normalize edilmiş çerçevelerin
// özeti olan parmak izi (aynı hata aynı parmak izini üretir) ve en üst çerçeve gider. Örnekleme ve sınır vardır: hata fırtınası
// toplayıcıyı doldurmaz. Parmak izi üretilmiş (minify) dosya adının özetsiz biçimiyle kurulur. Sembolleştirme için en üst beş çerçevenin
// konumu ayrıca gider (`frames`: yalnız dosya taban adı, satır, sütun, işlev adı; dizin, alan adı ve sorgu gitmez); sunucu yüklenen
// kaynak haritasıyla okuma anında çözer. `sourcePositions: false` bunu kapatır. Toplayıcı mesajı ayrıca temizler.
import type { Consent } from "./types";

/** Çekirdek SDK'nın modülün gördüğü yüzü; test için sahte örnek verilebilir. */
export interface ErrorsClient {
  track(eventName: string, properties?: Record<string, unknown>): unknown;
  getStatus(): { consent: Consent } | null;
}

export interface ErrorsOptions {
  client: ErrorsClient;
  /** Test/SSR için enjekte edilebilir pencere. */
  window?: Pick<Window, "addEventListener" | "removeEventListener">;
  /** Uygulama sürümü (≤32); sürüm kırılımı ve kaynak haritası eşlemesi için. Verilmezse alan gönderilmez. */
  appVersion?: string;
  /** Sembolleştirme için çerçeve konumları (`frames`) gönderilsin mi (varsayılan true). */
  sourcePositions?: boolean;
  /** Örnekleme oranı 0..1 (varsayılan 1). Yalnız kayıp kabul edilen yüksek hacimde düşürün. */
  sampleRate?: number;
  /** Sayfa yüklemesi başına en çok bu kadar hata olayı (varsayılan 20). */
  maxEvents?: number;
  /** Aynı parmak izi için sayfa yüklemesi başına en çok bu kadar olay (varsayılan 3). */
  maxPerFingerprint?: number;
  /** Test için rastgele kaynağı enjekte etme. */
  random?: () => number;
}

export interface ErrorsHandle {
  /** Yakalanan (try/catch) bir hatayı elle bildirir: `handled: true`, `origin: "handled"`. */
  capture(error: unknown, options?: { origin?: "handled" | "manual" }): boolean;
  stop(): void;
}

export type ErrorOrigin = "window_onerror" | "unhandledrejection" | "uncaught_exception" | "handled" | "manual";

export const ERROR_EVENT_NAME = "fr_error";
const MAX_MESSAGE = 200;
const MAX_TYPE = 64;
const MAX_FRAME = 160;
const MAX_FRAMES_IN_FINGERPRINT = 5;
const MAX_STACK_LINES = 50;

/** FNV-1a 64 bit; senkron çalışır (hata anında asenkron API beklenmez). 16 küçük harf onaltılı. */
export function fnv1a64(text: string): string {
  let hash = 0xcbf29ce484222325n;
  for (let i = 0; i < text.length; i++) hash = BigInt.asUintN(64, (hash ^ BigInt(text.charCodeAt(i))) * 0x100000001b3n);
  return hash.toString(16).padStart(16, "0");
}

/** Mesajdan e-posta, URL, uzun sayı ve uzun belirteçleri çıkarır; toplayıcı aynı temizliği sunucuda tekrar uygular. */
export function scrubMessage(message: string): string {
  return message
    .replace(/\b[a-z][a-z0-9+.-]*:\/\/[^\s"'<>]+/gi, "[url]")
    .replace(/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/g, "[email]")
    .replace(/\b[A-Za-z0-9_\-+/=]{24,}\b/g, (m) => (/\d/.test(m) ? "[token]" : m))
    .replace(/\+?\d[\d\s\-().]{5,}\d/g, (m) => (m.replace(/\D/g, "").length >= 7 ? "[num]" : m))
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, MAX_MESSAGE);
}

/** Dosya yolunu kararlı kısa ada indirir: sorgu, parça ve derleme özeti çıkar (`app.3f9a1b2c.js` → `app.js`), dizin gitmez. */
export function normalizeFile(location: string): string {
  const cleaned = location.split("#")[0]!.split("?")[0]!;
  const base = cleaned.split(/[\\/]/).filter(Boolean).pop() ?? "";
  return base.replace(/[.-][0-9a-f]{6,}(?=\.|$)/gi, "").slice(0, 80) || "unknown";
}

/**
 * Yığın izini normalize çerçevelere çevirir (`işlev@dosya`). Chrome (`at fn (url:1:2)`) ve Firefox/Safari (`fn@url:1:2`) biçimleri okunur.
 * Satır ve sütun numarası atılır: aynı hata, kod biraz kaydığında da aynı parmak izini üretsin.
 */
/**
 * V8 yığın izi `Tür: mesaj` başlığıyla başlar; mesajda `@` varsa (ör. e-posta) başlık Firefox çerçevesi sanılmasın diye V8 biçiminde
 * yalnız `at ` satırları okunur. Firefox ve Safari başlık yazmaz.
 */
function stackLines(stack: string): { lines: string[]; v8: boolean } {
  const lines = stack.split("\n").slice(0, MAX_STACK_LINES).map((raw) => raw.trim());
  return { lines, v8: lines.some((line) => line.startsWith("at ")) };
}

export function normalizeFrames(stack: unknown): string[] {
  if (typeof stack !== "string" || stack === "") return [];
  const frames: string[] = [];
  const { lines, v8 } = stackLines(stack);
  for (const line of lines) {
    let fn: string;
    let loc: string;
    const chrome = /^at\s+(?:(.*?)\s+\()?(.*?)(?::\d+)?(?::\d+)?\)?$/.exec(line);
    if (line.startsWith("at ") && chrome) {
      fn = chrome[1] ?? "";
      loc = chrome[2] ?? "";
    } else if (!v8 && line.includes("@")) {
      const at = line.lastIndexOf("@");
      fn = line.slice(0, at);
      loc = line.slice(at + 1).replace(/(?::\d+){1,2}$/, "");
    } else continue;
    // `new Foo`, `async fn`, `Object.fn [as alias]` gibi önekler ve takma adlar atılır.
    fn = fn.replace(/^(?:async|new)\s+/, "").replace(/\s*\[as [^\]]*\]$/, "").trim();
    const name = (fn || "<anonymous>").slice(0, 60);
    const file = loc ? normalizeFile(loc) : "unknown";
    frames.push(`${name}@${file}`);
  }
  return frames;
}

/** Sembolleştirilecek çerçeve: üretilmiş dosyanın taban adı (derleme özeti korunur), 1 tabanlı satır ve sütun. */
export interface SourcePosition {
  file: string;
  line: number;
  column: number;
  function?: string;
}

const MAX_POSITIONS = 5;
const FILE_BASENAME = /^[A-Za-z0-9._~-]{1,128}$/;

/**
 * Yığın izinden en üst beş çerçevenin konumu. Dosya yalnız taban adıyla gider (`https://cdn.x/assets/app.3f9a1b2c.js?v=1` →
 * `app.3f9a1b2c.js`): kaynak haritası bu adla eşlenir. Satır ve sütunu olmayan ya da adı güvenli karakter dışı çerçeve atlanır.
 */
export function sourcePositions(stack: unknown): SourcePosition[] {
  if (typeof stack !== "string" || stack === "") return [];
  const out: SourcePosition[] = [];
  const { lines, v8 } = stackLines(stack);
  for (const line of lines) {
    if (out.length >= MAX_POSITIONS) break;
    let fn: string;
    let loc: string;
    if (line.startsWith("at ")) {
      const m = /^at\s+(?:(.*?)\s+\()?(.*?)\)?$/.exec(line);
      if (!m) continue;
      fn = m[1] ?? "";
      loc = m[2] ?? "";
    } else if (!v8 && line.includes("@")) {
      const at = line.lastIndexOf("@");
      fn = line.slice(0, at);
      loc = line.slice(at + 1);
    } else continue;
    const pos = /:(\d+):(\d+)$/.exec(loc);
    if (!pos) continue;
    const file = loc.slice(0, pos.index).split("#")[0]!.split("?")[0]!.split(/[\\/]/).filter(Boolean).pop() ?? "";
    const lineNo = Number(pos[1]);
    const column = Number(pos[2]);
    if (!FILE_BASENAME.test(file) || lineNo < 1 || lineNo > 10_000_000 || column < 0 || column > 10_000_000) continue;
    const name = fn.replace(/^(?:async|new)\s+/, "").replace(/\s*\[as [^\]]*\]$/, "").trim().slice(0, 60);
    out.push(name ? { file, line: lineNo, column, function: name } : { file, line: lineNo, column });
  }
  return out;
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

function typeNameOf(error: unknown): string {
  if (error && typeof error === "object") {
    const e = error as { name?: unknown; constructor?: { name?: unknown } };
    if (typeof e.name === "string" && e.name) return e.name.slice(0, MAX_TYPE);
    if (typeof e.constructor?.name === "string" && e.constructor.name) return e.constructor.name.slice(0, MAX_TYPE);
  }
  return "Error";
}

/**
 * Hata gövdesini sözleşmeye göre kurar (packages/schemas/utp/v1/event.schema.json, `fr_error`). Parmak izi hata türü ve en üst
 * beş çerçevenin özetidir; çerçeve yoksa türün yanına rakamsız mesaj girer. Web hataları ölümcül sayılmaz (`fatal: false`).
 */
export function buildErrorProperties(error: unknown, origin: ErrorOrigin, appVersion?: string, fallbackLocation?: string, withPositions = true): ErrorProperties {
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
  if (frames.length === 0 && fallbackLocation) frames.push(`<anonymous>@${normalizeFile(fallbackLocation)}`);
  const message = scrubMessage(rawMessage);
  const basis = frames.length > 0 ? frames.slice(0, MAX_FRAMES_IN_FINGERPRINT).join("|") : message.replace(/\d+/g, "#");
  const props: ErrorProperties = {
    error_type: errorType,
    fingerprint: fnv1a64(`${errorType}|${basis}`),
    frame_count: Math.min(frames.length, 1000),
    handled: origin === "handled" || origin === "manual",
    fatal: false,
    origin,
  };
  if (message) props.message = message;
  if (frames[0]) props.top_frame = frames[0].slice(0, MAX_FRAME);
  if (appVersion && appVersion.length <= 32) props.app_version = appVersion;
  if (withPositions) {
    const positions = sourcePositions(stack);
    if (positions.length > 0) props.frames = positions;
  }
  return props;
}

/**
 * Hata yakalamayı başlatır. İzin kapısı çekirdek SDK'dadır: `consent.analytics` yoksa `track` olay üretmez. Dinleyiciler yalnız
 * dinler; hatayı yutmaz ve sayfanın kendi hata işleyicilerini engellemez.
 */
export function captureErrors(options: ErrorsOptions): ErrorsHandle {
  const { client } = options;
  const win = options.window ?? (typeof window !== "undefined" ? window : undefined);
  const sampleRate = Math.min(1, Math.max(0, options.sampleRate ?? 1));
  const maxEvents = Math.max(0, options.maxEvents ?? 20);
  const maxPerFingerprint = Math.max(1, options.maxPerFingerprint ?? 3);
  const random = options.random ?? Math.random;
  const perFingerprint = new Map<string, number>();
  let sent = 0;

  const report = (error: unknown, origin: ErrorOrigin, fallbackLocation?: string): boolean => {
    if (sent >= maxEvents) return false;
    if (sampleRate < 1 && random() >= sampleRate) return false;
    const props = buildErrorProperties(error, origin, options.appVersion, fallbackLocation, options.sourcePositions !== false);
    const seen = perFingerprint.get(props.fingerprint) ?? 0;
    if (seen >= maxPerFingerprint) return false;
    perFingerprint.set(props.fingerprint, seen + 1);
    sent++;
    client.track(ERROR_EVENT_NAME, props as unknown as Record<string, unknown>);
    return true;
  };

  const onError = (event: Event): void => {
    const e = event as Event & { error?: unknown; message?: string; filename?: string };
    // Çapraz kaynaklı betikte `error` null olur ve mesaj "Script error." gelir: türü sabit, parmak izi dosya adından türer.
    const error = e.error ?? { name: "ScriptError", message: e.message ?? "" };
    report(error, "window_onerror", e.filename);
  };
  const onRejection = (event: Event): void => {
    const reason = (event as Event & { reason?: unknown }).reason;
    report(reason instanceof Error ? reason : { name: "UnhandledRejection", message: typeof reason === "string" ? reason : "" }, "unhandledrejection");
  };

  win?.addEventListener("error", onError);
  win?.addEventListener("unhandledrejection", onRejection);
  return {
    capture(error: unknown, opts?: { origin?: "handled" | "manual" }): boolean {
      return report(error, opts?.origin ?? "handled");
    },
    stop(): void {
      win?.removeEventListener("error", onError);
      win?.removeEventListener("unhandledrejection", onRejection);
    },
  };
}
