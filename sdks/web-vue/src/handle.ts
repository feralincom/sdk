// Çerçeve bağdaştırıcılarının ortak tarayıcı katmanı. Bu dosya sdks/web-react, sdks/web-vue, sdks/web-angular ve
// sdks/tauri altında birebir aynıdır; her paketin testi eşitliği denetler. Sunucuda istemci kurulmaz (istek başına
// zamanlayıcı ve paylaşılan durum olmasın). Çekirdek de reklam izni yokken fr_click çıkarır; buradaki süzgeç zararsız bir
// tekrardır, serileştirme denetimi ise yalnız bu katmandadır.
import { Feralin, assertProjectKey } from "@feralin/web";
import type { Consent, FeralinOptions, FlushResult, RevenueInput, UtpEvent } from "@feralin/web";

export type { Consent, FeralinOptions, FlushResult, RevenueInput, UtpEvent };
export type FeralinStatus = ReturnType<Feralin["getStatus"]>;

const CLICK_PROPERTY = "fr_click";
const EMPTY_FLUSH: FlushResult = { sent: 0, status: 0 };

/** Uygulamanın gördüğü yüzey. Sunucuda ve Provider dışında aynı metotlar güvenle hiçbir şey yapmaz. */
export interface FeralinHandle {
  /** Gerçek istemciye bağlıysa true; sunucuda false. Ekrana basılacak içeriği buna bağlamayın, hydration uyuşmaz. */
  readonly active: boolean;
  track(eventName: string, properties?: Record<string, unknown>): UtpEvent | null;
  page(properties?: Record<string, unknown>): UtpEvent | null;
  /**
   * Satın alma ya da abonelik beyanı (`feralin_purchase`); kurallar çekirdekteki `trackRevenue` ile aynıdır. İstemci beyanıdır, `verified`
   * gönderilmez; geçersiz girdide null.
   */
  trackRevenue(input: RevenueInput): UtpEvent | null;
  identify(userId: string): void;
  /** `fr_group` olayı (UTP §8.2); grup kimliği geçersizse null. */
  group(groupId: string, traits?: Record<string, unknown>): UtpEvent | null;
  /** `fr_user_properties` olayı; kişisel veriye benzeyen anahtar düşer, geçerli özellik yoksa null. */
  setUserProperties(properties: Record<string, unknown>): UtpEvent | null;
  /** `fr_` dışındaki her olaya eklenecek özellikler; `null` anahtarı siler. */
  setGlobalProperties(properties: Record<string, unknown>): void;
  clearGlobalProperties(): void;
  setConsent(consent: Consent): void;
  optOut(): void;
  reset(): void;
  /** Tek sayfalı uygulamada önceki ekranın adresi (yalnız origin gönderilir); boş değer geçersiz kılmayı kaldırır. */
  setReferrer(url?: string): void;
  flush(): Promise<FlushResult>;
  getStatus(): FeralinStatus | null;
}

export const noopFeralin: FeralinHandle = Object.freeze({
  active: false,
  track: () => null,
  page: () => null,
  trackRevenue: () => null,
  identify: () => {},
  group: () => null,
  setUserProperties: () => null,
  setGlobalProperties: () => {},
  clearGlobalProperties: () => {},
  setConsent: () => {},
  optOut: () => {},
  reset: () => {},
  setReferrer: () => {},
  flush: () => Promise.resolve(EMPTY_FLUSH),
  getStatus: () => null,
});

export function isBrowser(): boolean {
  return typeof window !== "undefined" && typeof document !== "undefined";
}

/** Reklam izni yoksa fr_click çıkarılır. Serileştirilemeyen değer null döner: kuyruğa girip batch'i zehirlemesin. */
function prepareProperties(client: Feralin, properties: Record<string, unknown> | undefined): Record<string, unknown> | undefined | null {
  if (!properties) return properties;
  let out = properties;
  if (CLICK_PROPERTY in properties && client.getStatus().consent.advertising !== true) {
    const { [CLICK_PROPERTY]: _removed, ...rest } = properties;
    out = rest;
  }
  try {
    JSON.stringify(out);
  } catch {
    return null;
  }
  return out;
}

/** Çekirdek istemciyi uygulamayı düşürmeyen yüzeye çevirir. */
export function wrapFeralin(client: Feralin): FeralinHandle {
  const emit = (eventName: string, properties?: Record<string, unknown>): UtpEvent | null => {
    try {
      const prepared = prepareProperties(client, properties);
      return prepared === null ? null : client.track(eventName, prepared);
    } catch {
      return null;
    }
  };
  return {
    active: true,
    track: emit,
    page: (properties) => emit("page_view", properties),
    trackRevenue: (input) => {
      try {
        if (!input || typeof input !== "object") return null;
        const prepared = prepareProperties(client, input.properties);
        return prepared === null ? null : client.trackRevenue({ ...input, properties: prepared });
      } catch {
        return null;
      }
    },
    identify: (userId) => client.identify(userId),
    group: (groupId, traits) => {
      try {
        return client.group(groupId, traits);
      } catch {
        return null;
      }
    },
    setUserProperties: (properties) => {
      try {
        return client.setUserProperties(properties);
      } catch {
        return null;
      }
    },
    setGlobalProperties: (properties) => {
      try {
        client.setGlobalProperties(properties);
      } catch {
        // Uygulama düşmez; düşen anahtarlar çekirdeğin hata ayıklama günlüğündedir.
      }
    },
    clearGlobalProperties: () => client.clearGlobalProperties(),
    setConsent: (consent) => client.setConsent(consent && typeof consent === "object" ? consent : { analytics: false }),
    optOut: () => client.optOut(),
    reset: () => client.reset(),
    setReferrer: (url) => client.setReferrer(typeof url === "string" ? url : undefined),
    flush: () => client.flush().catch(() => EMPTY_FLUSH),
    getStatus: () => client.getStatus(),
  };
}

const clients = new Map<string, { client: Feralin; handle: FeralinHandle }>();
let primary: FeralinHandle | undefined;

function clientKey(options: FeralinOptions): string {
  // Çekirdek anahtarı kırptığı için boşluklu ve kırpılmış değer aynı istemcidir.
  return `${String(options.projectKey).trim()}\n${options.collectUrl}`;
}

/**
 * Tarayıcıda proje ve toplayıcı başına tek istemci verir; StrictMode'un çift çağrısı ve yeniden bağlama ikinci
 * page_view üretmez. Sunucuda istemci kurmadan noop döner. Yalnız public anahtar (pk_) kabul edilir, her iki tarafta da.
 */
export function acquireFeralin(options: FeralinOptions): FeralinHandle {
  assertProjectKey(options?.projectKey);
  if (!isBrowser()) return noopFeralin;
  const key = clientKey(options);
  let entry = clients.get(key);
  if (!entry) {
    const client = new Feralin(options);
    entry = { client, handle: wrapFeralin(client) };
    clients.set(key, entry);
  }
  primary ??= entry.handle;
  return entry.handle;
}

/** İstemciyi bırakır: zamanlayıcı ve sayfa dinleyicileri kalkar, eski tutamak göndermez ve depoya yazmaz. Kuyruk depoda kalır; aynı seçeneklerle sonraki çağrı yeni istemci kurar ve kuyruğu okur. */
export function releaseFeralin(options: Pick<FeralinOptions, "projectKey" | "collectUrl">): void {
  const key = clientKey(options as FeralinOptions);
  const entry = clients.get(key);
  if (!entry) return;
  entry.client.destroy();
  clients.delete(key);
  if (primary === entry.handle) primary = undefined;
}

/** Çağrı anında ilk kurulan istemciye gider; bileşen ağacı dışındaki kod ve Provider'sız kullanım içindir. */
export const ambientFeralin: FeralinHandle = {
  get active() {
    return primary !== undefined;
  },
  track: (eventName, properties) => (primary ?? noopFeralin).track(eventName, properties),
  page: (properties) => (primary ?? noopFeralin).page(properties),
  trackRevenue: (input) => (primary ?? noopFeralin).trackRevenue(input),
  identify: (userId) => (primary ?? noopFeralin).identify(userId),
  group: (groupId, traits) => (primary ?? noopFeralin).group(groupId, traits),
  setUserProperties: (properties) => (primary ?? noopFeralin).setUserProperties(properties),
  setGlobalProperties: (properties) => (primary ?? noopFeralin).setGlobalProperties(properties),
  clearGlobalProperties: () => (primary ?? noopFeralin).clearGlobalProperties(),
  setConsent: (consent) => (primary ?? noopFeralin).setConsent(consent),
  optOut: () => (primary ?? noopFeralin).optOut(),
  reset: () => (primary ?? noopFeralin).reset(),
  setReferrer: (url) => (primary ?? noopFeralin).setReferrer(url),
  flush: () => (primary ?? noopFeralin).flush(),
  getStatus: () => (primary ?? noopFeralin).getStatus(),
};
