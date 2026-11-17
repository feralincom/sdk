// UTP §8.2 kimlik yöntemleri (Web SDK packages/sdk-web/src/profile.ts ile aynı dosya): `group` → `fr_group`, `setUserProperties` → `fr_user_properties`, `setGlobalProperties` (her olaya eklenen
// bellek içi özellikler). Kurallar bütün SDK'larda ve toplayıcıda (services/collect/internal/httpapi/profile_filter.go) birebir aynıdır;
// toplayıcı ayrıca projenin izin listesini uygular (liste boşsa hiçbir kullanıcı özelliği saklanmaz).

export const GROUP_EVENT_NAME = "fr_group";
export const USER_PROPERTIES_EVENT_NAME = "fr_user_properties";
/** Çağrı başına ve global haritada en çok bu kadar özellik. */
export const PROFILE_MAX_PROPERTIES = 50;
/** Dizge değerin en çok karakter (kod noktası) sayısı. */
export const PROFILE_MAX_VALUE_LENGTH = 256;
export const PROFILE_MAX_GROUP_ID_LENGTH = 128;

export type ProfileValue = string | number | boolean;
export type ProfileDropReason = "invalid_key" | "reserved" | "pii_like" | "invalid_value" | "limit";
export type ProfileDrop = { key: string; reason: ProfileDropReason };

const KEY = /^[a-zA-Z][a-zA-Z0-9_]{0,63}$/;
const EMAIL = /[^\s@]+@[^\s@]+\.[^\s@]+/;
const CONTROL = /\p{Cc}/u;
/** İstemci doğrulama beyan edemez: sunucu alanları düşer. */
const RESERVED = new Set(["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"]);
// Kişisel veri anahtar kuralı (toplayıcıdaki piiTokens, piiFragments, piiExact ile aynı listeler).
const PII_TOKENS = new Set([
  "email", "mail", "phone", "tel", "telephone", "mobile", "msisdn", "gsm",
  "ip", "ipv4", "ipv6", "ssn", "tckn", "passport", "password", "iban",
  "address", "adres", "eposta", "telefon", "soyad", "surname", "firstname",
  "lastname", "fullname", "birthdate", "birthday", "dob",
]);
const PII_FRAGMENTS = ["email", "phonenumber", "ipaddress", "firstname", "lastname", "fullname", "surname", "soyad", "eposta", "telefon", "password", "birthdate"];
const PII_EXACT = new Set(["name", "username", "displayname", "isim", "ad"]);

/** Anahtarı sözcüklere böler: küçük harf ya da rakamdan sonra gelen büyük harf yeni sözcük başlatır; alt çizgi ayırıcıdır. */
export function profileKeyTokens(key: string): string[] {
  const chars = [...key];
  let out = "";
  chars.forEach((ch, i) => {
    const prev = chars[i - 1];
    if (i > 0 && /\p{Lu}/u.test(ch) && prev !== undefined && /[\p{Ll}\p{Nd}]/u.test(prev)) out += "_";
    out += ch.toLowerCase();
  });
  return out.split("_").filter((token) => token !== "");
}

/** Anahtar kişisel veriye (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) benziyor mu. */
export function isPIILikeKey(key: string): boolean {
  const tokens = profileKeyTokens(key);
  if (tokens.some((token) => PII_TOKENS.has(token))) return true;
  const joined = tokens.join("");
  if (PII_EXACT.has(joined)) return true;
  return PII_FRAGMENTS.some((fragment) => joined.includes(fragment));
}

function validValue(value: unknown): value is ProfileValue {
  if (typeof value === "boolean") return true;
  if (typeof value === "number") return Number.isFinite(value);
  if (typeof value !== "string") return false;
  return [...value].length <= PROFILE_MAX_VALUE_LENGTH && !EMAIL.test(value) && !CONTROL.test(value);
}

/**
 * Özellikleri kimlik sözleşmesine indirger. `allowNull` yalnız global özellikte açıktır: `null` o anahtarı siler. Düşen her anahtar
 * nedeniyle döner (değer döndürülmez); çağıran uyarı yazar.
 */
export function sanitizeProfileProperties(input: Record<string, unknown> | undefined | null, allowNull = false): { properties: Record<string, ProfileValue | null>; dropped: ProfileDrop[] } {
  const properties: Record<string, ProfileValue | null> = {};
  const dropped: ProfileDrop[] = [];
  if (!input || typeof input !== "object") return { properties, dropped };
  let count = 0;
  for (const [key, value] of Object.entries(input)) {
    if (!KEY.test(key)) { dropped.push({ key: key.slice(0, 64), reason: "invalid_key" }); continue; }
    if (RESERVED.has(key)) { dropped.push({ key, reason: "reserved" }); continue; }
    if (isPIILikeKey(key)) { dropped.push({ key, reason: "pii_like" }); continue; }
    if (value === null && allowNull) {
      properties[key] = null;
    } else if (validValue(value)) {
      if (count >= PROFILE_MAX_PROPERTIES) { dropped.push({ key, reason: "limit" }); continue; }
      properties[key] = value;
      count++;
    } else {
      dropped.push({ key, reason: "invalid_value" });
    }
  }
  return { properties, dropped };
}

/** Grup kimliği: 1-128 karakter, yalnız boşluk değil, `@` ve kontrol karakteri yok (kişisel veri taşımamalı). */
export function validGroupId(groupId: unknown): groupId is string {
  if (typeof groupId !== "string" || groupId.trim() === "") return false;
  if ([...groupId].length > PROFILE_MAX_GROUP_ID_LENGTH) return false;
  return !groupId.includes("@") && !CONTROL.test(groupId);
}

/** Global özellikler `fr_` sistem olaylarına eklenmez: toplayıcı bu gövdelerde izin listesi dışı alanı düşürür ya da reddeder. */
export function acceptsGlobalProperties(eventName: string): boolean {
  return !eventName.startsWith("fr_");
}

/** Global haritaya birleştirir: `null` siler, yeni anahtar sınırı aşarsa düşer. */
export function mergeGlobalProperties(current: Map<string, ProfileValue>, input: Record<string, unknown> | undefined | null): ProfileDrop[] {
  const { properties, dropped } = sanitizeProfileProperties(input, true);
  for (const [key, value] of Object.entries(properties)) {
    if (value === null) { current.delete(key); continue; }
    if (!current.has(key) && current.size >= PROFILE_MAX_PROPERTIES) { dropped.push({ key, reason: "limit" }); continue; }
    current.set(key, value);
  }
  return dropped;
}
