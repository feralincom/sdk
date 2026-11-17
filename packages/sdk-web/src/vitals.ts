// Feralin Web SDK — Core Web Vitals modülü (UI-066, ayrı giriş noktası, çekirdek bütçesine girmez).
// Tarayıcının kendi `PerformanceObserver` girdileri okunur: LCP (`largest-contentful-paint`), INP (`event` + `first-input`),
// CLS (`layout-shift`) ve TTFB (gezinme zamanlaması). Her ölçüt sayfa yüklemesi başına en çok bir kez `fr_web_vital` olayına çevrilir.
// Veri modeli: yalnız ölçüt adı, değer, derece ve gezinme türü gider. Öğe seçicisi, URL, kaynak adı, ekran ölçüsü ya da cihaz
// özelliği GİTMEZ; parmak izi üretilmez. Sayfa yolu ve kaba cihaz sınıfı çekirdek SDK bağlamından ve toplayıcıdan gelir.
// İzin kapısı çekirdek SDK'dadır: `consent.analytics` yoksa `track` olay üretmez.
import type { Consent } from "./types";

/** Çekirdek SDK'nın modülün gördüğü yüzü; test için sahte örnek verilebilir. */
export interface VitalsClient {
  track(eventName: string, properties?: Record<string, unknown>): unknown;
  getStatus(): { consent: Consent } | null;
}

export type VitalName = "LCP" | "INP" | "CLS" | "TTFB";
export type VitalRating = "good" | "needs_improvement" | "poor";
export type NavigationType = "navigate" | "reload" | "back_forward" | "prerender";

export const VITAL_EVENT_NAME = "fr_web_vital";
export const VITAL_NAMES: readonly VitalName[] = ["LCP", "INP", "CLS", "TTFB"];
const NAVIGATION_TYPES: readonly NavigationType[] = ["navigate", "reload", "back_forward", "prerender"];

/** Kabul edilen en büyük değer (ms; CLS birimsiz). Üstü ölçüm hatası sayılır ve gönderilmez; toplayıcı aynı sınırı uygular. */
export const VITAL_MAX: Record<VitalName, number> = { LCP: 60_000, INP: 60_000, CLS: 10, TTFB: 60_000 };

/** web.dev eşikleri: [iyi üst sınırı, zayıf alt sınırı]. Derece istemcide yalnız bilgi amaçlıdır; sunucu p75'i kendisi derecelendirir. */
export const VITAL_THRESHOLDS: Record<VitalName, readonly [number, number]> = { LCP: [2500, 4000], INP: [200, 500], CLS: [0.1, 0.25], TTFB: [800, 1800] };

/** INP: yüksek gecikmeli en çok bu kadar etkileşim tutulur; her 50 etkileşimde en kötüsü aykırı sayılıp atlanır (web.dev tanımı). */
const INP_CANDIDATES = 10;
/** CLS oturum penceresi: kaymalar arası en çok 1 sn, pencere en çok 5 sn. */
const CLS_GAP_MS = 1000;
const CLS_WINDOW_MS = 5000;

export function rateVital(name: VitalName, value: number): VitalRating {
  const [good, poor] = VITAL_THRESHOLDS[name];
  return value <= good ? "good" : value <= poor ? "needs_improvement" : "poor";
}

export interface VitalProperties {
  metric: VitalName;
  value: number;
  rating: VitalRating;
  navigation_type?: NavigationType;
}

/** Olay gövdesini sözleşmeye göre kurar (packages/schemas/utp/v1/event.schema.json, `fr_web_vital`). Geçersiz değer null döner. */
export function buildVitalProperties(name: VitalName, raw: number, navigationType?: NavigationType): VitalProperties | null {
  if (!VITAL_NAMES.includes(name) || typeof raw !== "number" || !Number.isFinite(raw) || raw < 0) return null;
  // Süreler tam milisaniyeye, CLS dört ondalığa yuvarlanır: daha ince çözünürlük ölçüm değil gürültüdür.
  const value = name === "CLS" ? Math.round(raw * 10_000) / 10_000 : Math.round(raw);
  if (value > VITAL_MAX[name]) return null;
  const props: VitalProperties = { metric: name, value, rating: rateVital(name, value) };
  if (navigationType) props.navigation_type = navigationType;
  return props;
}

/** Etkileşim gecikmesi listesinden INP: en kötü etkileşim, her 50 etkileşimde bir aykırı değer atlanarak. */
export function inpFrom(longest: readonly number[], interactionCount: number): number | null {
  if (longest.length === 0 || interactionCount === 0) return null;
  const sorted = [...longest].sort((a, b) => b - a);
  return sorted[Math.min(sorted.length - 1, Math.floor(interactionCount / 50))] ?? null;
}

type PerfEntry = { entryType: string; startTime: number; duration: number; interactionId?: number; value?: number; hadRecentInput?: boolean };
type ObserverCtor = new (callback: (list: { getEntries(): PerfEntry[] }) => void) => { observe(init: Record<string, unknown>): void; disconnect(): void };
type NavEntry = { responseStart: number; activationStart?: number; type?: string };

export interface VitalsOptions {
  client: VitalsClient;
  /** Test/SSR için enjekte edilebilir pencere, belge, zamanlama ve gözlemci. */
  window?: Pick<Window, "addEventListener" | "removeEventListener">;
  document?: Pick<Document, "addEventListener" | "removeEventListener" | "visibilityState">;
  performance?: { getEntriesByType(type: string): unknown[] };
  PerformanceObserver?: ObserverCtor & { supportedEntryTypes?: readonly string[] };
  /** Sayfa yüklemesi başına örnekleme oranı 0..1 (varsayılan 1); karar yüklemede bir kez verilir. */
  sampleRate?: number;
  random?: () => number;
}

export interface VitalsHandle {
  /** Bekleyen ölçütleri hemen bildirir (LCP, CLS, INP); her ölçüt yine en çok bir kez gider. */
  report(): void;
  stop(): void;
}

/**
 * Ölçümü başlatır. Ölçütler sayfa gizlenince (`visibilitychange` → hidden, `pagehide`) bildirilir; LCP ilk kullanıcı girdisinde de
 * kesinleşir, TTFB gezinme yanıtı gelince hemen gider. Dinleyiciler yakalama evresine bağlanır: çekirdek SDK aynı olayda kuyruğu
 * gönderdiği için ölçüt olayları ondan önce kuyruğa girer. Tarayıcı bir girdi türünü desteklemiyorsa o ölçüt gönderilmez, tahmin edilmez.
 */
export function captureVitals(options: VitalsOptions): VitalsHandle {
  const { client } = options;
  const win = options.window ?? (typeof window !== "undefined" ? window : undefined);
  const doc = options.document ?? (typeof document !== "undefined" ? document : undefined);
  const perf = options.performance ?? (typeof performance !== "undefined" ? performance : undefined);
  const Observer = options.PerformanceObserver ?? (typeof PerformanceObserver !== "undefined" ? (PerformanceObserver as unknown as ObserverCtor & { supportedEntryTypes?: readonly string[] }) : undefined);
  const sampleRate = Math.min(1, Math.max(0, options.sampleRate ?? 1));
  const random = options.random ?? Math.random;
  const noop: VitalsHandle = { report() {}, stop() {} };
  if (!Observer || !win || !doc) return noop;
  if (sampleRate < 1 && random() >= sampleRate) return noop;

  const nav = (perf?.getEntriesByType("navigation")[0] ?? undefined) as NavEntry | undefined;
  const activationStart = Math.max(0, nav?.activationStart ?? 0);
  const navigationType: NavigationType | undefined = activationStart > 0 ? "prerender" : NAVIGATION_TYPES.find((type) => type === nav?.type);
  const supported = Observer.supportedEntryTypes;
  const supports = (type: string) => !supported || supported.includes(type);
  const sent = new Set<VitalName>();
  const observers: Array<{ disconnect(): void }> = [];

  const emit = (name: VitalName, value: number | null): void => {
    if (value === null || sent.has(name)) return;
    const props = buildVitalProperties(name, value, navigationType);
    if (!props) return;
    sent.add(name);
    client.track(VITAL_EVENT_NAME, props as unknown as Record<string, unknown>);
  };
  const observe = (type: string, onEntries: (entries: PerfEntry[]) => void, extra: Record<string, unknown> = {}): void => {
    if (!supports(type)) return;
    try {
      const observer = new Observer((list) => onEntries(list.getEntries()));
      observer.observe({ type, buffered: true, ...extra });
      observers.push(observer);
    } catch {
      // Eski tarayıcı `type` biçimini tanımıyor: ölçüt gönderilmez.
    }
  };

  // LCP: sayfa ilk boyamadan önce gizlendiyse anlamsızdır, ölçülmez. Değer gezinme etkinleşmesine (önceden işleme) göre düzeltilir.
  let lcp: number | null = null;
  const lcpEligible = doc.visibilityState !== "hidden";
  if (lcpEligible) observe("largest-contentful-paint", (entries) => {
    const last = entries[entries.length - 1];
    if (last) lcp = Math.max(0, last.startTime - activationStart);
  });

  // CLS: kullanıcı girdisinden hemen sonraki kaymalar sayılmaz; en büyük oturum penceresinin toplamı.
  let cls = 0;
  let clsSeen = false;
  let windowValue = 0;
  let windowFirst = -Infinity;
  let windowLast = -Infinity;
  observe("layout-shift", (entries) => {
    clsSeen = true;
    for (const entry of entries) {
      if (entry.hadRecentInput || typeof entry.value !== "number") continue;
      if (entry.startTime - windowLast < CLS_GAP_MS && entry.startTime - windowFirst < CLS_WINDOW_MS) {
        windowValue += entry.value;
      } else {
        windowValue = entry.value;
        windowFirst = entry.startTime;
      }
      windowLast = entry.startTime;
      cls = Math.max(cls, windowValue);
    }
  });

  // INP: aynı etkileşimin olayları `interactionId` ile birleşir; etkileşim başına en uzun süre alınır.
  const byInteraction = new Map<number, number>();
  let dropped = 0;
  const onInteractions = (entries: PerfEntry[]): void => {
    for (const entry of entries) {
      if (!entry.interactionId) continue;
      byInteraction.set(entry.interactionId, Math.max(byInteraction.get(entry.interactionId) ?? 0, entry.duration));
      if (byInteraction.size > INP_CANDIDATES * 50) {
        // Bellek sınırı: en kısa etkileşimler atılır, sayaç korunur.
        const keep = [...byInteraction.entries()].sort((a, b) => b[1] - a[1]).slice(0, INP_CANDIDATES);
        dropped += byInteraction.size - keep.length;
        byInteraction.clear();
        for (const [id, duration] of keep) byInteraction.set(id, duration);
      }
    }
  };
  observe("event", onInteractions, { durationThreshold: 40 });
  observe("first-input", onInteractions);

  // TTFB: gezinme yanıtının ilk baytı; yanıt henüz gelmediyse yükleme olayında okunur.
  const reportTtfb = (): void => {
    const entry = (perf?.getEntriesByType("navigation")[0] ?? undefined) as NavEntry | undefined;
    if (entry && entry.responseStart > 0) emit("TTFB", Math.max(0, entry.responseStart - activationStart));
  };
  if (nav && nav.responseStart > 0) reportTtfb();
  else win.addEventListener("load", reportTtfb);

  const finalizeLcp = (): void => {
    if (lcpEligible) emit("LCP", lcp);
  };
  const reportAll = (): void => {
    finalizeLcp();
    if (clsSeen || supports("layout-shift")) emit("CLS", cls);
    const longest = [...byInteraction.values()].sort((a, b) => b - a).slice(0, INP_CANDIDATES);
    emit("INP", inpFrom(longest, byInteraction.size + dropped));
  };
  const onHidden = (): void => {
    if (doc.visibilityState === "hidden") reportAll();
  };
  // İlk girdi LCP'yi kesinleştirir: sonradan beliren büyük öğe kullanıcının gördüğü ilk yüklemeyi temsil etmez.
  const onInput = (): void => finalizeLcp();
  const listen = { capture: true } as const;
  doc.addEventListener("visibilitychange", onHidden, listen);
  win.addEventListener("pagehide", reportAll, listen);
  win.addEventListener("keydown", onInput, { capture: true, once: true });
  win.addEventListener("pointerdown", onInput, { capture: true, once: true });

  return {
    report: reportAll,
    stop(): void {
      for (const observer of observers) observer.disconnect();
      observers.length = 0;
      doc.removeEventListener("visibilitychange", onHidden, listen);
      win.removeEventListener("pagehide", reportAll, listen);
      win.removeEventListener("keydown", onInput, listen);
      win.removeEventListener("pointerdown", onInput, listen);
      win.removeEventListener("load", reportTtfb);
    },
  };
}
