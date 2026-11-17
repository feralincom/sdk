// Feralin App Banner (FAZ_DENETIMI madde 35): mobil web sayfasında, ziyaretçiyi bir Smart Link üzerinden uygulamaya
// götüren küçük bir şerit. Ölçüm yapmaz: çerez yazmaz, olay göndermez, cihazı tanımlamaz. Tıklama Smart Link'in
// kendisine gider ve orada sayılır. Kapatma tercihi yalnız sekme ömrünce (sessionStorage) hatırlanır.

export type BannerPlatform = "ios" | "android";

export interface BannerOptions {
  /** Smart Link adresi; yalnız https. */
  link: string;
  title: string;
  text?: string;
  cta: string;
  closeLabel: string;
  platforms: BannerPlatform[];
  position: "top" | "bottom";
}

export interface BannerEnvironment {
  document: Document;
  userAgent: string;
  /** Yoksa ya da erişilemiyorsa kapatma tercihi hatırlanmaz; şerit yine çalışır. */
  storage?: Pick<Storage, "getItem" | "setItem"> | null;
}

export const BANNER_DISMISS_KEY = "feralin_banner_dismissed";
const LIMITS = { title: 60, text: 120, cta: 24, closeLabel: 40 } as const;
const PLATFORMS: readonly BannerPlatform[] = ["ios", "android"];

/**
 * Platform yalnız User-Agent dizgisinden okunur; ek cihaz sinyali toplanmaz. Masaüstü kipindeki iPad kendini Mac olarak
 * tanıtır ve burada tanınmaz: yanlış platforma şerit göstermektense hiç göstermemek tercih edilir.
 */
export function bannerPlatform(userAgent: string): BannerPlatform | null {
  if (/iPhone|iPad|iPod/.test(userAgent)) return "ios";
  if (/Android/.test(userAgent)) return "android";
  return null;
}

function clean(value: string | undefined, max: number): string {
  // Denetim ve biçim karakterleri atılır; metin DOM'a yalnız textContent ile yazılır.
  return (value ?? "").replace(/[\p{Cc}\p{Cf}]/gu, " ").replace(/\s+/g, " ").trim().slice(0, max);
}

function httpsUrl(raw: string | undefined): string | null {
  try {
    const url = new URL((raw ?? "").trim());
    return url.protocol === "https:" && url.host !== "" && url.username === "" && url.password === "" ? url.toString() : null;
  } catch {
    return null;
  }
}

/** `data-*` değerlerinden seçenekler. Geçersiz ya da eksik zorunlu alan varsa null: yarım şerit çizilmez. */
export function resolveBannerOptions(data: Record<string, string | undefined>): BannerOptions | null {
  const link = httpsUrl(data.link);
  const title = clean(data.title, LIMITS.title);
  const cta = clean(data.cta, LIMITS.cta);
  if (!link || !title || !cta) return null;
  const requested = (data.platforms ?? "").split(",").map((item) => item.trim().toLowerCase());
  const platforms = PLATFORMS.filter((platform) => requested.includes(platform));
  const text = clean(data.text, LIMITS.text);
  return {
    link,
    title,
    ...(text ? { text } : {}),
    cta,
    closeLabel: clean(data.closeLabel, LIMITS.closeLabel) || "Kapat",
    platforms: platforms.length > 0 ? platforms : [...PLATFORMS],
    position: data.position === "top" ? "top" : "bottom",
  };
}

function dismissed(storage: BannerEnvironment["storage"]): boolean {
  try {
    return storage?.getItem(BANNER_DISMISS_KEY) === "1";
  } catch {
    return false;
  }
}

function style(element: HTMLElement, rules: Record<string, string>): void {
  for (const [name, value] of Object.entries(rules)) element.style.setProperty(name, value);
}

/**
 * Şeridi sayfaya ekler. Şu durumlarda hiçbir şey çizmez ve null döner: platform hedefte değil (masaüstü dahil),
 * ziyaretçi bu sekmede kapatmış, sayfada zaten bir şerit var.
 */
export function mountBanner(input: BannerOptions, env: BannerEnvironment): HTMLElement | null {
  // `window.feralinBanner.mount` ile doğrudan çağrıda da aynı denetim geçer: https olmayan bağlantı (ör. `javascript:`)
  // ve sınırı aşan metin betik etiketi yolundaki gibi reddedilir ya da kırpılır.
  const options = resolveBannerOptions({
    link: input?.link,
    title: input?.title,
    text: input?.text,
    cta: input?.cta,
    closeLabel: input?.closeLabel,
    platforms: Array.isArray(input?.platforms) ? input.platforms.join(",") : undefined,
    position: input?.position,
  });
  if (!options) return null;
  const platform = bannerPlatform(env.userAgent);
  if (!platform || !options.platforms.includes(platform)) return null;
  if (dismissed(env.storage)) return null;
  const doc = env.document;
  if (!doc.body || doc.querySelector("[data-feralin-banner]")) return null;

  const root = doc.createElement("div");
  root.setAttribute("data-feralin-banner", platform);
  root.setAttribute("role", "region");
  root.setAttribute("aria-label", options.title);
  style(root, {
    position: "fixed",
    left: "0",
    right: "0",
    [options.position]: "0",
    "z-index": "2147483000",
    display: "flex",
    "align-items": "center",
    gap: "12px",
    // Çentikli ve hareket çubuklu ekranlarda içerik güvenli alanın içinde kalır.
    padding: options.position === "bottom" ? "10px 12px calc(10px + env(safe-area-inset-bottom, 0px))" : "calc(10px + env(safe-area-inset-top, 0px)) 12px 10px",
    "box-sizing": "border-box",
    "max-height": "40vh",
    overflow: "auto",
    background: "#ffffff",
    color: "#111827",
    "border-top": options.position === "bottom" ? "1px solid #e5e7eb" : "0",
    "border-bottom": options.position === "top" ? "1px solid #e5e7eb" : "0",
    font: "14px/1.35 system-ui, -apple-system, 'Segoe UI', Roboto, sans-serif",
  });

  const copy = doc.createElement("div");
  style(copy, { flex: "1 1 auto", "min-width": "0", "overflow-wrap": "anywhere" });
  const title = doc.createElement("strong");
  title.textContent = options.title;
  style(title, { display: "block", "font-weight": "600" });
  copy.appendChild(title);
  if (options.text) {
    const text = doc.createElement("span");
    text.textContent = options.text;
    style(text, { display: "block", color: "#4b5563", "font-size": "13px" });
    copy.appendChild(text);
  }

  const cta = doc.createElement("a");
  cta.setAttribute("href", options.link);
  cta.setAttribute("rel", "noopener");
  cta.textContent = options.cta;
  style(cta, { flex: "0 0 auto", padding: "8px 14px", "border-radius": "999px", background: "#2563eb", color: "#ffffff", "text-decoration": "none", "font-weight": "600", "white-space": "nowrap" });

  const close = doc.createElement("button");
  close.setAttribute("type", "button");
  close.setAttribute("aria-label", options.closeLabel);
  close.textContent = "×";
  style(close, { flex: "0 0 auto", width: "44px", height: "44px", border: "0", background: "transparent", color: "#4b5563", "font-size": "22px", "line-height": "1", cursor: "pointer" });
  close.addEventListener("click", () => {
    root.remove();
    try {
      env.storage?.setItem(BANNER_DISMISS_KEY, "1");
    } catch {
      // Depolama kapalıysa tercih hatırlanmaz; şerit bu sayfada yine kapanır.
    }
  });

  root.appendChild(copy);
  root.appendChild(cta);
  root.appendChild(close);
  doc.body.appendChild(root);
  return root;
}

function sessionStore(): Storage | null {
  try {
    return window.sessionStorage;
  } catch {
    return null;
  }
}

/** Betik etiketindeki `data-*` değerleriyle kendiliğinden çalışır; `window.feralinBanner.mount` ile elle de çağrılabilir. */
function autoMount(): void {
  if (typeof document === "undefined" || typeof navigator === "undefined") return;
  const script = document.currentScript as HTMLScriptElement | null;
  const options = script ? resolveBannerOptions(script.dataset as Record<string, string | undefined>) : null;
  if (!options) return;
  const run = () => mountBanner(options, { document, userAgent: navigator.userAgent, storage: sessionStore() });
  if (document.body) run();
  else document.addEventListener("DOMContentLoaded", run, { once: true });
}

autoMount();
