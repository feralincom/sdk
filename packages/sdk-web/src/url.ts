// URL temizliği: sorgu ve parça gönderilmez; sıklıkla token ve kişisel veri taşırlar. Yalnız utm_* ve Feralin kısa link kodu (fr_link) korunur.
const UTM_KEYS = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"];
const MAX_UTM_LENGTH = 256;
/** Feralin kısa link kodu: yönlendirici web hedefine ekler; kod kısa adreste zaten herkese açıktır, kişi ya da tıklama kimliği değildir. */
const LINK_PARAM = "fr_link";
const LINK_CODE = /^[a-z0-9][a-z0-9-]{2,63}$/;
/** Reklam tıklama kimliği parametreleri (öncelik sırası). Yalnız TÜRÜ taşınır (fr_click_type), değer reklam kimliğidir ve gönderilmez. */
const CLICK_ID_PARAMS = ["gclid", "gbraid", "wbraid", "dclid", "msclkid", "ttclid", "li_fat_id", "twclid", "yclid", "epik", "sccid", "rdt_cid", "irclickid", "fbclid", "igshid", "gad_source"];

function parse(raw: string): URL | null {
  try {
    const u = new URL(raw);
    return u.host ? u : null; // about:blank, file: gibi hostsuz adresler anlamsız
  } catch {
    return null;
  }
}

/** scheme+host+path ve varsa utm_* değerleri. Ayrıştırılamazsa url yoktur (şema boş `uri` kabul etmez). */
export function cleanPage(raw: string): { url?: string; utm: Record<string, string> } {
  const u = parse(raw);
  const utm: Record<string, string> = {};
  if (!u) return { utm };
  for (const key of UTM_KEYS) {
    const value = u.searchParams.get(key)?.trim();
    if (value) utm[key] = value.slice(0, MAX_UTM_LENGTH);
  }
  const link = u.searchParams.get(LINK_PARAM)?.trim();
  if (link && LINK_CODE.test(link)) utm[LINK_PARAM] = link;
  const click = CLICK_ID_PARAMS.find((param) => u.searchParams.get(param)?.trim());
  if (click) utm.fr_click_type = click;
  return { url: `${u.protocol}//${u.host}${u.pathname}`, utm };
}

/** Yalnız origin; ayrıştırılamayan veya boş referrer boş döner. */
export function cleanReferrer(raw: string): string {
  const u = parse(raw);
  return u ? `${u.protocol}//${u.host}` : "";
}

const MAX_REFERRER_PATH = 128;
const MAX_SEARCH_QUERY = 100;
const EMAIL = /[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+[.]\p{L}{2,}/gu;
const LONG_DIGITS = /\p{Nd}([ ()./-]{0,3}\p{Nd}){5,}/gu;

/** Arama motoru alan adı → sorgu parametreleri. Toplayıcının listesiyle aynıdır (services/collect/internal/dims/search.go). */
function searchParams(hostname: string): string[] | null {
  const host = hostname.toLowerCase().replace(/\.$/, "");
  const h = host.replace(/^www\./, "");
  if (h.startsWith("google.")) return ["q"];
  if (h === "bing.com" || h === "cn.bing.com") return ["q"];
  if (host.includes("search.yahoo.")) return ["p"];
  if (h === "duckduckgo.com" || h === "html.duckduckgo.com") return ["q"];
  if (h.startsWith("yandex.") || h === "ya.ru") return ["text"];
  if (h === "baidu.com" || h === "m.baidu.com") return ["wd", "word"];
  if (h === "ecosia.org" || h === "search.brave.com" || h === "qwant.com" || h === "ask.com" || h === "seznam.cz" || h === "search.seznam.cz") return ["q"];
  if (h === "startpage.com") return ["query", "q"];
  if (h === "search.naver.com" || h === "m.search.naver.com") return ["query"];
  return null;
}

/** Kaba "alan adı + son iki etiket" kuralı (toplayıcının iç/dış ayrımıyla aynı): `a.co.uk` gibi üç etiketli son ekler ayrıca ele alınır. */
function registrable(hostname: string): string {
  const labels = hostname.toLowerCase().split(".");
  if (labels.length <= 2) return labels.join(".");
  const second = labels[labels.length - 2] ?? "";
  const last = labels[labels.length - 1] ?? "";
  if (last.length === 2 && ["co", "com", "org", "net", "gov", "edu", "ac"].includes(second)) return labels.slice(-3).join(".");
  return labels.slice(-2).join(".");
}

/** Arama sorgusu: küçük harf, boşluk sadeleşir, e-posta ve en az altı rakamlı dizi maskelenir, en çok 100 karakter. */
export function cleanSearchQuery(raw: string): string {
  const q = raw.replace(/\p{Cc}/gu, " ").replace(/\s+/g, " ").trim().toLowerCase().replace(EMAIL, "***@***").replace(LONG_DIGITS, "###");
  return Array.from(q).slice(0, MAX_SEARCH_QUERY).join("").trim();
}

/**
 * Harici yönlendirenin ayrıntısı: yalnız yol (sorgu ve parça yok, e-posta maskelenir, en çok 128 karakter) ve bilinen arama motorunun sorgusu.
 * İç yönlendirende (aynı site) ve boş yönlendirende hiçbir şey dönmez. Çoğu arama motoru sorguyu göndermez (yalnız origin): o zaman sorgu yoktur.
 */
export function referrerDetail(raw: string, pageHref: string): { referrer_path?: string; search_query?: string } {
  const u = parse(raw);
  if (!u) return {};
  const page = parse(pageHref);
  if (page && (page.hostname === u.hostname || registrable(page.hostname) === registrable(u.hostname))) return {};
  const out: { referrer_path?: string; search_query?: string } = {};
  let path = u.pathname;
  try {
    const decoded = decodeURIComponent(path);
    const masked = decoded.replace(EMAIL, "_email_");
    if (masked !== decoded) path = encodeURI(masked);
  } catch {
    // Bozuk kaçışlı yol olduğu gibi kalır; toplayıcı yeniden denetler.
  }
  path = Array.from(path).slice(0, MAX_REFERRER_PATH).join("");
  if (path.startsWith("/") && path !== "/") out.referrer_path = path;
  const params = searchParams(u.hostname);
  if (params) {
    for (const param of params) {
      const q = cleanSearchQuery(u.searchParams.get(param) ?? "");
      if (q) {
        out.search_query = q;
        break;
      }
    }
  }
  return out;
}
