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
