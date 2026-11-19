// Feralin Web SDK — Smart Script (Adjust karşılaştırması madde 15; ayrı giriş noktası, çekirdek bütçesine girmez, ölçüm SDK'sı gerekmez).
// Açılış sayfasındaki mağaza ve uygulama bağlantılarını Feralin kısa linkine çevirir ve sayfanın geldiği reklam bilgisini (UTM ile
// tıklama kimlikleri) linke ekler. Böylece web reklamından gelen ziyaretçi uygulamayı kurduğunda kurulum o kampanyaya atfedilebilir.
// Kısa link yönlendiricisi gelen UTM ve tıklama kimliklerini hedefe taşır ve linkin kendi UTM'si önceliklidir; bu betik linkte zaten
// olan parametreye dokunmaz.
// Veri: yalnız sayfa adresindeki kapalı listedeki parametreler ve (isteğe bağlı) yönlendirenin alan adı. Çerez yazılmaz; parametreler
// yalnız oturum boyunca (`sessionStorage`) tutulur ki aynı ziyarette başka sayfaya geçilince kaybolmasın. Kişisel veri okunmaz.

/** UTM anahtarları (link yönlendiricisiyle aynı sıra). */
export const SMART_UTM_KEYS = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"] as const;

/**
 * Reklam tıklama kimlikleri. Liste link yönlendiricisinin taşıdığı listeyle aynıdır (`services/link-router/internal/target/passthrough.go`
 * `PassClickIDParams`); test iki listeyi karşılaştırır.
 */
export const SMART_CLICK_IDS = ["gclid", "gbraid", "wbraid", "dclid", "gad_source", "msclkid", "fbclid", "ttclid", "li_fat_id", "twclid", "yclid", "epik", "sccid", "rdt_cid", "irclickid", "igshid"] as const;

/** Varsayılan hedef: App Store, Google Play, AppGallery ve Galaxy Store bağlantıları ile `data-feralin-smart` işaretli öğeler. */
export const SMART_DEFAULT_SELECTOR = 'a[href*="apps.apple.com"], a[href*="itunes.apple.com"], a[href*="play.google.com/store"], a[href*="appgallery.huawei.com"], a[href*="galaxystore.samsung.com"], [data-feralin-smart]';

const STORAGE_KEY = "feralin_smart_params";
const MAX_VALUE = 256;

export interface SmartScriptOptions {
  /** Feralin kısa link adresi (ör. `https://feralin.com/l/abc123`). Yalnız https kabul edilir. */
  link: string;
  /** Yeniden yazılacak öğelerin CSS seçicisi; verilmezse `SMART_DEFAULT_SELECTOR`. */
  selector?: string;
  /**
   * Sayfada UTM yoksa yönlendirenin alan adını `utm_source`, `referral` değerini `utm_medium` olarak ekle (ör. organik arama).
   * Varsayılan `false`: yalnız açık kampanya bilgisi taşınır.
   */
  referrerAsSource?: boolean;
}

interface Doc {
  querySelectorAll(selector: string): ArrayLike<{ getAttribute(name: string): string | null; setAttribute(name: string, value: string): void; tagName?: string }>;
  referrer?: string;
}

type SafeStorage = { getItem(key: string): string | null; setItem(key: string, value: string): void } | null;

function clean(value: string | null): string | null {
  if (value === null) return null;
  const v = value.trim();
  if (v === "" || v.length > MAX_VALUE || /[\s\u0000-\u001f\u007f]/.test(v)) return null;
  return v;
}

/** Sayfa adresinden ve yönlendirenden taşınacak parametreleri çıkarır. Geçersiz değer atlanır. */
export function collectSmartParams(pageUrl: string, referrer: string | undefined, options: Pick<SmartScriptOptions, "referrerAsSource"> = {}): Record<string, string> {
  const out: Record<string, string> = {};
  let page: URL;
  try {
    page = new URL(pageUrl);
  } catch {
    return out;
  }
  for (const key of [...SMART_UTM_KEYS, ...SMART_CLICK_IDS]) {
    const value = clean(page.searchParams.get(key));
    if (value) out[key] = value;
  }
  if (options.referrerAsSource && !out.utm_source && referrer) {
    try {
      const ref = new URL(referrer);
      if ((ref.protocol === "https:" || ref.protocol === "http:") && ref.hostname !== page.hostname) {
        out.utm_source = ref.hostname;
        out.utm_medium = out.utm_medium ?? "referral";
      }
    } catch {
      // Çözümlenemeyen yönlendiren atlanır.
    }
  }
  return out;
}

/** Kısa linke parametreleri ekler; linkte zaten olan parametre korunur. Link https değilse `null`. */
export function buildSmartUrl(link: string, params: Record<string, string>): string | null {
  let url: URL;
  try {
    url = new URL(link);
  } catch {
    return null;
  }
  if (url.protocol !== "https:") return null;
  for (const [key, value] of Object.entries(params)) {
    if (!url.searchParams.has(key)) url.searchParams.set(key, value);
  }
  return url.toString();
}

function sessionStore(): SafeStorage {
  try {
    return typeof sessionStorage === "undefined" ? null : sessionStorage;
  } catch {
    return null;
  }
}

/**
 * Bu ziyaretin parametreleri: sayfada parametre varsa onlar (ve oturuma yazılır), yoksa aynı oturumda daha önce görülenler.
 * Depolama kullanılamıyorsa yalnız sayfadakiler.
 */
export function visitParams(pageUrl: string, referrer: string | undefined, options: Pick<SmartScriptOptions, "referrerAsSource"> = {}, storage: SafeStorage = sessionStore()): Record<string, string> {
  const current = collectSmartParams(pageUrl, referrer, options);
  if (Object.keys(current).length > 0) {
    try {
      storage?.setItem(STORAGE_KEY, JSON.stringify(current));
    } catch {
      // Depolama kotası ya da gizli kip: yalnız bu sayfa kullanılır.
    }
    return current;
  }
  try {
    const saved = storage?.getItem(STORAGE_KEY);
    if (!saved) return current;
    const parsed = JSON.parse(saved) as Record<string, unknown>;
    const out: Record<string, string> = {};
    for (const key of [...SMART_UTM_KEYS, ...SMART_CLICK_IDS]) {
      const value = typeof parsed[key] === "string" ? clean(parsed[key] as string) : null;
      if (value) out[key] = value;
    }
    return out;
  } catch {
    return current;
  }
}

/**
 * Seçicideki öğeleri kısa linke çevirir ve kaç öğenin değiştiğini döner. `<a>` öğesinin `href`'i, öteki öğelerde `data-href`
 * yazılır. İşlenen öğe `data-feralin-smart-applied` ile işaretlenir; betik ikinci kez çağrılırsa aynı sonucu üretir.
 */
export function applySmartScript(options: SmartScriptOptions, doc: Doc = document as unknown as Doc, pageUrl: string = location.href, storage: SafeStorage = sessionStore()): number {
  const params = visitParams(pageUrl, doc.referrer, options, storage);
  const target = buildSmartUrl(options.link, params);
  if (!target) return 0;
  const nodes = doc.querySelectorAll(options.selector ?? SMART_DEFAULT_SELECTOR);
  let changed = 0;
  for (let i = 0; i < nodes.length; i += 1) {
    const node = nodes[i];
    if (!node) continue;
    const isAnchor = (node.tagName ?? "").toUpperCase() === "A";
    node.setAttribute(isAnchor ? "href" : "data-href", target);
    node.setAttribute("data-feralin-smart-applied", "1");
    changed += 1;
  }
  return changed;
}
