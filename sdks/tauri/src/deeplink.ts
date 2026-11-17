// Derin bağlantı (deep link) ile açılış: Android SDK'daki `FeralinEngine.emitDeepLink` ve `AttributionParams.parseQuery` kurallarının
// masaüstü karşılığı. Ham URL saklanmaz ve gönderilmez; sorgudan yalnız `fr_click` ve standart `utm_*` okunur, o da yalnız açık reklam
// ölçümü izniyle olaya yazılır. İzin yoksa açılış `attribution_source: "none"` ile sayılır, kanıt gönderilmez.

export const DEEP_LINK_EVENT_NAME = "deep_link_opened";
export const ATTRIBUTION_SOURCE_APP_LINK = "app_link";
export const ATTRIBUTION_SOURCE_NONE = "none";

const FR_CLICK = "fr_click";
const FR_CLICK_PATTERN = /^[A-Za-z0-9._~-]{1,256}$/;
const UTM_KEYS: readonly string[] = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"];
const MAX_VALUE_LENGTH = 256;
const MAX_URL_LENGTH = 2048;
const SCHEME_PATTERN = /^[a-z][a-z0-9+.-]{0,31}$/;

export interface AttributionParams {
  frClick?: string;
  utm: Record<string, string>;
}

/** Katı çözümleme: `+` boşluktur; bozuk `%XX` ya da geçersiz UTF-8 parçayı yok saydırır. */
function decode(text: string): string | null {
  try {
    return decodeURIComponent(text.replace(/\+/g, " "));
  } catch {
    return null;
  }
}

/** `a=b&c=d` dizgisini izin listesiyle ayrıştırır; bilinmeyen parametre okunmaz. Aynı anahtarın ilk geçerli değeri kullanılır. */
export function parseAttributionQuery(raw: string | null | undefined): AttributionParams {
  const out: AttributionParams = { utm: {} };
  if (!raw || !raw.trim()) return out;
  // Bazı kampanya araçları sorgunun tamamını bir kez daha kodlar.
  const text = !raw.includes("=") && /%3D/i.test(raw) ? decode(raw) ?? raw : raw;
  for (const pair of text.split("&")) {
    const eq = pair.indexOf("=");
    if (eq <= 0) continue;
    const key = decode(pair.slice(0, eq));
    if (key === null || (key !== FR_CLICK && !UTM_KEYS.includes(key))) continue;
    const value = decode(pair.slice(eq + 1))?.trim() ?? "";
    if (!value) continue;
    if (key === FR_CLICK) {
      if (out.frClick === undefined && FR_CLICK_PATTERN.test(value)) out.frClick = value;
    } else if (!(key in out.utm)) {
      out.utm[key] = value.slice(0, MAX_VALUE_LENGTH);
    }
  }
  return out;
}

/** Yapılandırmadaki şemaları denetler (`myapp`, `https`); `://` ve büyük harf kabul edilmez, hata kurulumda fırlar. */
export function normalizeSchemes(schemes: unknown): ReadonlySet<string> {
  if (!Array.isArray(schemes) || schemes.length === 0) throw new Error("feralin: deepLinks.schemes en az bir şema içermeli");
  const out = new Set<string>();
  for (const entry of schemes as unknown[]) {
    const scheme = typeof entry === "string" ? entry.trim().toLowerCase() : "";
    if (!SCHEME_PATTERN.test(scheme)) throw new Error(`feralin: geçersiz deep link şeması: ${JSON.stringify(entry)} (ör. "myapp", "https")`);
    out.add(scheme);
  }
  return out;
}

export interface ParsedDeepLink {
  /** `şema://host/yol`; sorgu ve parça yoktur. */
  cleanUrl: string;
  params: AttributionParams;
}

/** İzinli şemadaki URL'i ayrıştırır; uymayan, çözümlenemeyen ya da 2048 karakteri aşan değer null döner. */
export function parseDeepLink(raw: unknown, schemes: ReadonlySet<string>): ParsedDeepLink | null {
  if (typeof raw !== "string" || !raw || raw.length > 8192) return null;
  let url: URL;
  try {
    url = new URL(raw.trim());
  } catch {
    return null;
  }
  const scheme = url.protocol.replace(/:$/, "").toLowerCase();
  if (!schemes.has(scheme)) return null;
  const cleanUrl = `${scheme}://${url.host}${url.pathname}`;
  if (cleanUrl.length > MAX_URL_LENGTH) return null;
  return { cleanUrl, params: parseAttributionQuery(url.search.replace(/^\?/, "")) };
}

/** Olay özellikleri (Android ile aynı): reklam ölçümü izni varsa `app_link` ve varsa kanıt, yoksa yalnız `none`. */
export function deepLinkProperties(link: ParsedDeepLink, advertising: boolean): Record<string, string> {
  if (!advertising) return { attribution_source: ATTRIBUTION_SOURCE_NONE };
  const props: Record<string, string> = { attribution_source: ATTRIBUTION_SOURCE_APP_LINK };
  if (link.params.frClick !== undefined) props[FR_CLICK] = link.params.frClick;
  Object.assign(props, link.params.utm);
  return props;
}
