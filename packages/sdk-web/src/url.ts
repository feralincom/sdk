// URL temizliği: sorgu ve parça gönderilmez; sıklıkla token ve kişisel veri taşırlar. Yalnız utm_* korunur.
const UTM_KEYS = ["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content"];
const MAX_UTM_LENGTH = 256;

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
  return { url: `${u.protocol}//${u.host}${u.pathname}`, utm };
}

/** Yalnız origin; ayrıştırılamayan veya boş referrer boş döner. */
export function cleanReferrer(raw: string): string {
  const u = parse(raw);
  return u ? `${u.protocol}//${u.host}` : "";
}
