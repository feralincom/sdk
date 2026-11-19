// Web yedeği: tarayıcıda (capacitor serve, PWA) çağrılar Feralin Web SDK'sına (@feralin/web) gider. Kurulum, mağaza, push belirteci
// ve ertelenmiş derin bağlantı web'de yoktur; bunlar dürüstçe `not_supported` ya da null döner, sahte başarı üretilmez.
import type { Consent, FirstOpenOptions, NativeConfig, NativeFeralin } from "./definitions.js";

/** @feralin/web modülünden kullanılan yüz; testler sahte modül verir. */
export interface WebSdkModule {
  initialize(options: {
    projectKey: string;
    collectUrl: string;
    consent?: Consent;
    flushIntervalMs?: number;
    batchSize?: number;
    debug?: boolean;
    installCode?: string;
  }): WebClient;
  sanitizeProfileProperties?(input: Record<string, unknown>, allowNull?: boolean): { properties: Record<string, unknown> };
}

export interface WebClient {
  track(name: string, properties?: Record<string, unknown>): { event_id: string } | null;
  trackRevenue(input: Record<string, unknown>): { event_id: string } | null;
  identify(userId: string): void;
  group(groupId: string, traits?: Record<string, unknown>): { event_id: string } | null;
  setUserProperties(properties: Record<string, unknown>): { event_id: string } | null;
  setGlobalProperties(properties: Record<string, unknown>): void;
  clearGlobalProperties(): void;
  setConsent(consent: Consent): void;
  flush(): Promise<{ sent: number; accepted?: number; rejected?: number; status: number; batch_id?: string }>;
  reset(): void;
  getStatus(): { sdk: string; version: string; queued: number; consent: Consent; anonymous_id?: string | null; session_id?: string | null; user_id?: string | null };
}

/** Web çekirdeği en çok 500 olaylık batch kabul eder. */
const WEB_MAX_BATCH = 500;

/** Adresin yolu ve sorgusu; `fr_` ile başlayan Feralin parametreleri çıkarılır. */
function destinationOf(raw: string): string {
  try {
    const url = new URL(raw);
    const params = new URLSearchParams();
    url.searchParams.forEach((value, key) => {
      if (!key.startsWith("fr_")) params.append(key, value);
    });
    const query = params.toString();
    return (url.pathname || "/") + (query ? `?${query}` : "");
  } catch {
    return "/";
  }
}

/** `load` web SDK modülünü verir (gerçek kullanımda `import("@feralin/web")`); modül yalnız ilk çağrıda yüklenir. */
export function createWebNative(load: () => Promise<WebSdkModule>): NativeFeralin {
  let sdk: WebSdkModule | null = null;
  let client: WebClient | null = null;

  const require = (): WebClient => {
    if (!client) throw new Error("feralin: initialize çağrılmadı");
    return client;
  };
  const eventId = (event: { event_id: string } | null) => ({ eventId: event?.event_id ?? null });

  return {
    async initialize({ config }: { config: NativeConfig }) {
      if (client) return { ready: true };
      sdk = await load();
      // Web çekirdeği kendi doğrulamasını yapar ve geçersiz anahtarda hata fırlatır; JS katmanı bunu `false` olarak döndürür.
      client = sdk.initialize({
        projectKey: config.projectKey,
        collectUrl: config.collectUrl,
        consent: config.consent,
        flushIntervalMs: config.flushIntervalMs,
        batchSize: config.batchSize === undefined ? undefined : Math.min(config.batchSize, WEB_MAX_BATCH),
        debug: config.debug,
        installCode: config.installCode,
      });
      return { ready: true };
    },
    async setConsent({ consent }) {
      require().setConsent(consent);
      return { ok: true };
    },
    async track({ name, properties }) {
      return eventId(require().track(name, properties ?? undefined));
    },
    async screen({ name, properties }) {
      // Android ve iOS köprüleriyle aynı: `screen_view` olayı, ekran adı `screen_name` özelliğinde.
      return eventId(require().track("screen_view", { ...(properties ?? {}), screen_name: name }));
    },
    async identify({ userId }) {
      require().identify(userId);
      return { ok: true };
    },
    async reset() {
      require().reset();
      return { ok: true };
    },
    async group({ groupId, traits }) {
      return eventId(require().group(groupId, traits ?? undefined));
    },
    async setUserProperties({ properties }) {
      return eventId(require().setUserProperties(properties));
    },
    async setGlobalProperties({ properties }) {
      const web = require();
      web.setGlobalProperties(properties);
      // Web çekirdeği kabul sayısını döndürmez; aynı kuralları uygulayan dışa açık temizleyiciyle sayılır.
      const accepted = sdk?.sanitizeProfileProperties?.(properties, true).properties;
      return { count: accepted ? Object.keys(accepted).length : 0 };
    },
    async clearGlobalProperties() {
      require().clearGlobalProperties();
      return { ok: true };
    },
    async trackRevenue({ input }) {
      return eventId(require().trackRevenue(input));
    },
    async flush() {
      const result = await require().flush();
      return { sent: result.sent, accepted: result.accepted ?? 0, rejected: result.rejected ?? 0, status: result.status, batchId: result.batch_id ?? null };
    },
    async trackFirstOpen(_options: { options: FirstOpenOptions }) {
      return { status: "not_supported", eventId: null };
    },
    async getInstallStore() {
      return { installStore: null };
    },
    async handleUniversalLink({ url }) {
      return { destination: destinationOf(url), linkCode: null, hasClickId: false };
    },
    async handleShortLink({ url }) {
      return { destination: destinationOf(url), linkCode: null, hasClickId: false };
    },
    async consumeDeferredDeepLink() {
      return { status: "not_supported", path: null, linkCode: null };
    },
    async setPushToken() {
      return { eventId: null };
    },
    async installIdentifier() {
      return { installId: null };
    },
    async getStatus() {
      if (!client) return { initialized: false };
      const status = client.getStatus();
      return {
        initialized: true,
        sdk: status.sdk,
        version: status.version,
        queued: status.queued,
        consent: status.consent,
        anonymousId: status.anonymous_id ?? null,
        sessionId: status.session_id ?? null,
        userId: status.user_id ?? null,
      };
    },
  };
}
