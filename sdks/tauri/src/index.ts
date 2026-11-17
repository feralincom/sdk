// Tauri JS tarafı: uygulamanın web görünümünde @feralin/web çalışır. Rust eklentisi yoktur; olaylar web görünümünden
// gönderilir, kuyruk web görünümünün localStorage alanındadır. Hata yakalama ve derin bağlantı isteğe bağlıdır (opt-in);
// ikisi de dışarıdan verilen işlevle bağlanır, böylece paket @tauri-apps/plugin-deep-link ya da hata modülüne bağımlı olmaz.
import { assertProjectKey } from "@feralin/web";
import { acquireFeralin, isBrowser, noopFeralin, releaseFeralin } from "./handle.js";
import type { FeralinHandle, FeralinOptions, UtpEvent } from "./handle.js";
import { DEEP_LINK_EVENT_NAME, deepLinkProperties, normalizeSchemes, parseDeepLink } from "./deeplink.js";

export { noopFeralin, releaseFeralin };
export type { Consent, FeralinHandle, FeralinOptions, FeralinStatus, FlushResult, RevenueInput, UtpEvent } from "./handle.js";
export { ATTRIBUTION_SOURCE_APP_LINK, ATTRIBUTION_SOURCE_NONE, DEEP_LINK_EVENT_NAME, parseAttributionQuery, parseDeepLink } from "./deeplink.js";
export type { AttributionParams, ParsedDeepLink } from "./deeplink.js";

/** Tauri 2 çalışma zamanı işareti. Tauri 1 `__TAURI__` nesnesini yalnız `withGlobalTauri` açıkken koyar. */
export function isTauri(): boolean {
  if (!isBrowser()) return false;
  const host = window as unknown as Record<string, unknown>;
  return host.__TAURI_INTERNALS__ !== undefined || host.__TAURI__ !== undefined;
}

/** `@feralin/web/errors` modülünün `captureErrors` işlevinin kullanılan şekli (yapısal tip; modül bu pakete bağlanmaz). */
export type CaptureErrorsFunction = (options: {
  client: { track(eventName: string, properties?: Record<string, unknown>): unknown; getStatus(): { consent: { analytics: boolean } } | null };
  appVersion?: string;
  sourcePositions?: boolean;
  sampleRate?: number;
  maxEvents?: number;
  maxPerFingerprint?: number;
}) => { capture(error: unknown, options?: { origin?: "handled" | "manual" }): boolean; stop(): void };

export interface FeralinTauriErrorsOptions {
  /** `import { captureErrors } from "@feralin/web/errors"` ile alınan işlev. */
  captureErrors: CaptureErrorsFunction;
  /** Uygulama sürümü (≤32); `fr_error.app_version`. */
  appVersion?: string;
  sourcePositions?: boolean;
  sampleRate?: number;
  maxEvents?: number;
  maxPerFingerprint?: number;
}

/** `@tauri-apps/plugin-deep-link` işlevlerinin kullanılan şekli: `onOpenUrl` ve isteğe bağlı `getCurrent`. */
export interface FeralinTauriDeepLinkOptions {
  /** Kabul edilen şemalar (ör. `["myapp"]`); `tauri.conf.json` içindeki `plugins.deep-link.desktop.schemes` ile aynı olmalı. */
  schemes: readonly string[];
  onOpenUrl(handler: (urls: string[]) => void): Promise<() => void> | (() => void);
  /** Uygulama bağlantıyla başlatıldıysa açılış URL'leri. */
  getCurrent?(): Promise<string[] | null | undefined>;
}

export interface FeralinTauriOptions extends FeralinOptions {
  /** Tauri dışında (ör. tarayıcıda `vite dev`) çalışırken olay üretmek için true. Varsayılan false: geliştirme verisi karışmasın. */
  allowOutsideTauri?: boolean;
  /** Verilirse pencerenin yakalanmamış hataları ve işlenmemiş Promise redleri `fr_error` olarak bildirilir. */
  errors?: FeralinTauriErrorsOptions;
  /** Verilirse sistem derin bağlantıları `deep_link_opened` olarak bildirilir. */
  deepLinks?: FeralinTauriDeepLinkOptions;
}

export interface FeralinTauriHandle extends FeralinHandle {
  /** Yakalanan bir hatayı `fr_error` olarak bildirir; `errors` verilmediyse ya da sınır aşıldıysa false. */
  captureError(error: unknown): boolean;
  /** URL'i `deep_link_opened` olarak işler; `deepLinks` verilmediyse, şema izinli değilse ya da izin yoksa null. */
  handleDeepLink(url: string): UtpEvent | null;
  /** Hata dinleyicilerini ve derin bağlantı aboneliğini kaldırır. */
  stop(): void;
}

const wired = new WeakMap<FeralinHandle, FeralinTauriHandle>();

function extend(handle: FeralinHandle, options: Pick<FeralinTauriOptions, "errors" | "deepLinks">): FeralinTauriHandle {
  // Yapılandırma hatası her çağrıda, istemci durumundan bağımsız fırlar.
  const schemes = options.deepLinks ? normalizeSchemes(options.deepLinks.schemes) : null;
  if (options.deepLinks && typeof options.deepLinks.onOpenUrl !== "function") throw new Error("feralin: deepLinks.onOpenUrl işlevi verilmeli (@tauri-apps/plugin-deep-link)");
  const { captureErrors, ...errorSettings } = options.errors ?? ({} as Partial<FeralinTauriErrorsOptions>);
  if (options.errors && typeof captureErrors !== "function") throw new Error("feralin: errors.captureErrors işlevi verilmeli (@feralin/web/errors)");
  const existing = wired.get(handle);
  if (existing) return existing;
  let errors: ReturnType<CaptureErrorsFunction> | null = null;
  let unlisten: (() => void) | null = null;
  let stopped = false;

  const handleDeepLink = (url: string): UtpEvent | null => {
    try {
      if (stopped || !schemes) return null;
      const link = parseDeepLink(url, schemes);
      if (!link) return null;
      const advertising = handle.getStatus()?.consent.advertising === true;
      return handle.track(DEEP_LINK_EVENT_NAME, deepLinkProperties(link, advertising));
    } catch {
      return null;
    }
  };

  const extended: FeralinTauriHandle = {
    ...handle,
    captureError: (error) => {
      try {
        return errors ? errors.capture(error) : false;
      } catch {
        return false;
      }
    },
    handleDeepLink,
    stop: () => {
      stopped = true;
      errors?.stop();
      errors = null;
      try {
        unlisten?.();
      } catch {
        // Eklentinin abonelik kaldırma hatası uygulamayı düşürmez.
      }
      unlisten = null;
    },
  };
  wired.set(handle, extended);
  if (!handle.active) return extended;

  if (captureErrors) {
    errors = captureErrors({ client: handle, ...errorSettings });
  }
  if (options.deepLinks && schemes) {
    const source = options.deepLinks;
    const deliver = (urls: unknown) => {
      if (Array.isArray(urls)) for (const url of urls) handleDeepLink(url as string);
    };
    // Windows ve Linux'ta ikinci örneğin URL'i, single-instance eklentisinin `deep-link` özelliği açıkken onOpenUrl'e iletilir.
    void Promise.resolve()
      .then(() => source.onOpenUrl(deliver))
      .then((off) => {
        if (stopped) off();
        else unlisten = off;
      })
      .catch(() => undefined);
    if (typeof source.getCurrent === "function") {
      void Promise.resolve()
        .then(() => source.getCurrent?.())
        .then(deliver)
        .catch(() => undefined);
    }
  }
  return extended;
}

/**
 * Masaüstü pencerede istemciyi kurar. autoTrack varsayılanı false: tek sayfalı uygulamada yükleme, sayfa görüntüleme
 * sayılmaz; ekran değişiminde `page()` çağrılır. Node ortamında ve Tauri dışında boş yüzey döner. Aynı anahtar ve adresle
 * ikinci çağrı ilk tutamağı döner; hata ve derin bağlantı bağlantıları bir kez kurulur.
 */
export function createFeralinTauri({ allowOutsideTauri = false, errors, deepLinks, ...options }: FeralinTauriOptions): FeralinTauriHandle {
  assertProjectKey(options?.projectKey);
  const handle = !isTauri() && !allowOutsideTauri ? noopFeralin : acquireFeralin({ autoTrack: false, ...options });
  return extend(handle, { errors, deepLinks });
}
