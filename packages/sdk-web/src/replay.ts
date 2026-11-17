// Feralin Web SDK — replay/heatmap etkileşim modülü (F4-E02-T02, ayrı giriş noktası, çekirdek bütçesine girmez).
// Veri modeli: DOM kaydı YOK, metin YOK, form değeri YOK, oturum oynatma YOK. Yalnız üç etkileşim olayı gider:
//   fr_replay_click  {sel, x, y, vp}   maskeli seçici, görünüm alanına göre yüzde koordinat, görünüm alanı sınıfı
//   fr_replay_scroll {depth, vp}       sayfanın en derin kaydırma yüzdesi (10 adım)
//   fr_replay_view   {sel, vp}         yalnız `data-fr-view` ile işaretli bölümlerin görünmesi
// Maskeleme kapatılamaz: seçenek yoktur. İzin kapısı çifttir: `consent.analytics` (çekirdek) ve `consent.session_replay` (burası);
// izin geri çekilince modül aynı anda susar (her olayda yeniden okunur). Toplayıcı aynı kuralları sunucuda da uygular.
import type { Consent } from "./types";

/** Çekirdek SDK'nın modülün gördüğü yüzü; test için sahte örnek verilebilir. */
export interface ReplayClient {
  track(eventName: string, properties?: Record<string, unknown>): unknown;
  getStatus(): { consent: Consent } | null;
}

export type ViewportClass = "xs" | "sm" | "md" | "lg" | "xl";

export interface ReplayOptions {
  client: ReplayClient;
  /** Test/SSR için enjekte edilebilir belge ve pencere. */
  document?: Document;
  window?: Window;
}

export interface ReplayHandle {
  stop(): void;
}

export const REPLAY_EVENT_CLICK = "fr_replay_click";
export const REPLAY_EVENT_SCROLL = "fr_replay_scroll";
export const REPLAY_EVENT_VIEW = "fr_replay_view";
/** Seçici üst sınırı; toplayıcı da aynı sınırı uygular. */
export const SELECTOR_MAX_LENGTH = 200;
/** Seçici en çok bu kadar atadan oluşur; daha derin ağaç `[masked]`e değil kısaltmaya düşer. */
const SELECTOR_MAX_DEPTH = 6;
const SCROLL_STEP = 10;
const SCROLL_THROTTLE_MS = 500;
/** Kimlik yalnız geliştirici yazımı biçimindeyse seçiciye girer: 6+ ardışık rakam (sipariş, kullanıcı no) ya da `@` görülürse düşer. */
const SAFE_ID = /^[A-Za-z_][A-Za-z0-9_-]{0,63}$/;
const RISKY_ID = /\d{6,}|@/;
const SAFE_TAG = /^[a-z][a-z0-9-]{0,31}$/;
const SAFE_INPUT_TYPE = /^[a-z]{1,20}$/;
/** Değer taşıyan ya da kullanıcı metni barındıran öğeler: alt ağaç hiç okunmaz. */
const VALUE_TAGS = new Set(["input", "textarea", "select", "option"]);

/** Görünüm alanı sınıfı; piksel genişlik gönderilmez (parmak izi). */
export function viewportClass(width: number): ViewportClass {
  if (width < 576) return "xs";
  if (width < 768) return "sm";
  if (width < 992) return "md";
  if (width < 1200) return "lg";
  return "xl";
}

function nthOfType(el: Element): number {
  let n = 1;
  let sibling = el.previousElementSibling;
  while (sibling) {
    if (sibling.tagName === el.tagName) n++;
    sibling = sibling.previousElementSibling;
  }
  return n;
}

/**
 * Maskeli seçici: yalnız etiket adı, güvenli `id` ve `:nth-of-type`. Sınıf adı, öznitelik değeri, metin, `href`, `value` hiç okunmaz.
 * `data-fr-mask` taşıyan ata görülünce zincir `[masked]` ile kesilir. Değer taşıyan öğe yalnız `input[type=…]` biçiminde yazılır
 * (`password` dahil türü yazılır, değeri asla). Çıktı toplayıcının kabul ettiği karakter kümesindedir.
 */
export function maskedSelector(target: Element): string {
  const parts: string[] = [];
  let el: Element | null = target;
  let depth = 0;
  while (el && depth < SELECTOR_MAX_DEPTH) {
    const tag = el.tagName.toLowerCase();
    if (tag === "html" || tag === "body") break;
    if (el.hasAttribute("data-fr-mask")) {
      parts.unshift("[masked]");
      break;
    }
    if (!SAFE_TAG.test(tag)) {
      parts.unshift("[masked]");
      break;
    }
    let part = tag;
    if (VALUE_TAGS.has(tag)) {
      const type = tag === "input" ? (el.getAttribute("type") ?? "text").toLowerCase() : "";
      part = type && SAFE_INPUT_TYPE.test(type) ? `${tag}[type=${type}]` : tag;
      parts.unshift(part);
      break;
    }
    const id = el.getAttribute("id");
    if (id && SAFE_ID.test(id) && !RISKY_ID.test(id)) {
      parts.unshift(`${tag}#${id}`);
      // Kimlik yeterince belirleyicidir; yukarı çıkılmaz.
      break;
    }
    const parent: Element | null = el.parentElement;
    if (parent && parent.children.length > 1) part = `${tag}:nth-of-type(${nthOfType(el)})`;
    parts.unshift(part);
    el = parent;
    depth++;
  }
  const selector = parts.join(" > ");
  return selector.length > SELECTOR_MAX_LENGTH ? selector.slice(selector.length - SELECTOR_MAX_LENGTH).replace(/^[^a-z[]*/, "") : selector;
}

function clamp(value: number): number {
  return Math.max(0, Math.min(100, Math.round(value)));
}

/**
 * Modülü başlatır. İzin yoksa dinleyiciler yine bağlanır ama hiçbir olay üretilmez ve DOM okunmaz; izin sonradan gelirse olay akmaya başlar,
 * geri çekilince durur. `stop()` dinleyicileri kaldırır ve son kaydırma derinliğini bir kez gönderir (izin varsa).
 */
export function startReplay(options: ReplayOptions): ReplayHandle {
  const doc = options.document ?? (typeof document !== "undefined" ? document : undefined);
  const win = options.window ?? (typeof window !== "undefined" ? window : undefined);
  if (!doc || !win) return { stop() {} };
  const client = options.client;
  const allowed = (): boolean => {
    const status = client.getStatus();
    return Boolean(status && status.consent.analytics && status.consent.session_replay === true);
  };
  const vp = (): ViewportClass => viewportClass(win.innerWidth || doc.documentElement.clientWidth || 0);

  const onClick = (event: Event): void => {
    if (!allowed()) return;
    const mouse = event as MouseEvent;
    const target = mouse.target instanceof Element ? mouse.target : null;
    if (!target) return;
    const width = win.innerWidth || doc.documentElement.clientWidth || 1;
    const height = win.innerHeight || doc.documentElement.clientHeight || 1;
    client.track(REPLAY_EVENT_CLICK, { sel: maskedSelector(target), x: clamp((mouse.clientX / width) * 100), y: clamp((mouse.clientY / height) * 100), vp: vp() });
  };

  let maxDepth = 0;
  let sentDepth = 0;
  let throttle: ReturnType<typeof setTimeout> | undefined;
  const measureDepth = (): number => {
    const root = doc.documentElement;
    const scrollTop = win.scrollY || win.pageYOffset || root.scrollTop || 0;
    const viewport = win.innerHeight || root.clientHeight || 0;
    const total = Math.max(root.scrollHeight, doc.body ? doc.body.scrollHeight : 0) || 1;
    const seen = Math.min(total, scrollTop + viewport);
    // 10'luk adıma aşağı yuvarlanır; tam sona ulaşınca 100.
    return seen >= total - 1 ? 100 : Math.floor(((seen / total) * 100) / SCROLL_STEP) * SCROLL_STEP;
  };
  const flushDepth = (): void => {
    if (!allowed()) return;
    if (maxDepth > sentDepth) {
      sentDepth = maxDepth;
      client.track(REPLAY_EVENT_SCROLL, { depth: maxDepth, vp: vp() });
    }
  };
  const onScroll = (): void => {
    if (!allowed()) return;
    maxDepth = Math.max(maxDepth, measureDepth());
    if (throttle) return;
    throttle = setTimeout(() => {
      throttle = undefined;
      flushDepth();
    }, SCROLL_THROTTLE_MS);
  };
  const onPageHide = (): void => flushDepth();

  doc.addEventListener("click", onClick, true);
  win.addEventListener("scroll", onScroll, { passive: true });
  win.addEventListener("pagehide", onPageHide);

  // Görünürlük yalnız açıkça işaretlenmiş bölümlerde ve bölüm başına bir kez; genel DOM taraması yapılmaz.
  let observer: IntersectionObserver | undefined;
  const seen = new WeakSet<Element>();
  const IO = (win as Window & { IntersectionObserver?: typeof IntersectionObserver }).IntersectionObserver;
  if (typeof IO === "function") {
    observer = new IO(
      (entries) => {
        if (!allowed()) return;
        for (const entry of entries) {
          if (!entry.isIntersecting || seen.has(entry.target)) continue;
          seen.add(entry.target);
          client.track(REPLAY_EVENT_VIEW, { sel: maskedSelector(entry.target), vp: vp() });
        }
      },
      { threshold: 0.5 },
    );
    doc.querySelectorAll("[data-fr-view]").forEach((el) => observer?.observe(el));
  }

  return {
    stop() {
      doc.removeEventListener("click", onClick, true);
      win.removeEventListener("scroll", onScroll);
      win.removeEventListener("pagehide", onPageHide);
      if (throttle) clearTimeout(throttle);
      throttle = undefined;
      observer?.disconnect();
      flushDepth();
    },
  };
}
