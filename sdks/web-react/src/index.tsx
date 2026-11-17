"use client";
// React bağdaştırıcısı: @feralin/web üstünde Provider ve hook'lar. Sunucu çıktısına DOM eklemez, hydration uyuşmazlığı üretmez.
import { Component, createContext, useContext, useEffect, useMemo, useRef } from "react";
import type { ContextType, ErrorInfo, ReactElement, ReactNode } from "react";
import { reportFrameworkError } from "./errors.js";
import type { FeralinErrorOptions } from "./errors.js";
import { acquireFeralin, ambientFeralin } from "./handle.js";
import type { Consent, FeralinHandle, FeralinOptions } from "./handle.js";

export { reportFrameworkError } from "./errors.js";
export type { FeralinErrorOptions } from "./errors.js";
export { acquireFeralin, noopFeralin, releaseFeralin } from "./handle.js";
export type { Consent, FeralinHandle, FeralinOptions, FeralinStatus, FlushResult, RevenueInput, UtpEvent } from "./handle.js";

const FeralinContext = createContext<FeralinHandle | null>(null);

/** Provider dışında ilk kurulan istemciye (ör. FeralinScript), o da yoksa güvenli boş yüzeye gider. */
export function useFeralin(): FeralinHandle {
  return useContext(FeralinContext) ?? ambientFeralin;
}

/** Tek bir istemciyi kurar; seçenekteki izin değişirse çekirdeğe iletir. Anahtar ve adres dışındaki sonraki değişiklikler yok sayılır. */
export function useFeralinClient(options: FeralinOptions): FeralinHandle {
  // eslint-disable-next-line react-hooks/exhaustive-deps -- bilinçli: yalnız anahtar ve adres değişince yeni istemci kurulur
  const handle = useMemo(() => acquireFeralin(options), [options.projectKey, options.collectUrl]);
  useConsentSync(handle, options.consent);
  return handle;
}

function useConsentSync(handle: FeralinHandle, consent: Consent | undefined): void {
  // Nesne kimliği değil değerler izlenir: her render'da yazılan satır içi nesne setConsent'i tetiklemesin.
  useEffect(() => {
    if (consent) handle.setConsent(consent);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- bilinçli: nesne kimliği değil izin değerleri izlenir
  }, [handle, consent === undefined, consent?.analytics, consent?.advertising, consent?.personalization, consent?.session_replay]);
}

export interface FeralinProviderProps extends FeralinOptions {
  children?: ReactNode;
}

export function FeralinProvider({ children, ...options }: FeralinProviderProps): ReactElement {
  const handle = useFeralinClient(options);
  return <FeralinContext.Provider value={handle}>{children}</FeralinContext.Provider>;
}

export interface PageViewOptions {
  /** İlk değer için olay üretme; çekirdeğin autoTrack'i ilk sayfayı zaten gönderir. Varsayılan true. */
  skipInitial?: boolean;
  properties?: Record<string, unknown>;
  /** Varsayılan: useFeralin() */
  feralin?: FeralinHandle;
}

/** SPA geçişleri: `key` (genellikle yol) değişince page_view üretir. null veya undefined anahtar olay üretmez. */
export function usePageView(key: string | null | undefined, options: PageViewOptions = {}): void {
  const fallback = useFeralin();
  const feralin = options.feralin ?? fallback;
  const previous = useRef<string | null>(null);
  const properties = useRef(options.properties);
  properties.current = options.properties;
  const skipInitial = options.skipInitial !== false;
  useEffect(() => {
    if (key === null || key === undefined || previous.current === key) return;
    const isFirst = previous.current === null;
    previous.current = key;
    if (isFirst && skipInitial) return;
    feralin.page(properties.current);
  }, [key, feralin, skipInitial]);
}

export interface FeralinErrorBoundaryFallbackProps {
  error: unknown;
  /** Hata durumunu temizler ve alt ağacı yeniden çizer. */
  reset: () => void;
}

export interface FeralinErrorBoundaryProps {
  children?: ReactNode;
  /** Hata sonrası çizilecek arayüz; işlev verilirse hata ve `reset` ile çağrılır. Verilmezse hiçbir şey çizilmez. */
  fallback?: ReactNode | ((props: FeralinErrorBoundaryFallbackProps) => ReactNode);
  /** Bildirimden sonra uygulamanın kendi işleyicisi; fırlatırsa yutulur. */
  onError?: (error: unknown, info: ErrorInfo) => void;
  /** Örnekleme, sınır, uygulama sürümü ve konum ayarları; aynı istemci için ilk bildirimde okunur. */
  errors?: FeralinErrorOptions;
  /** Varsayılan: en yakın FeralinProvider, yoksa ilk kurulan istemci. */
  feralin?: FeralinHandle;
}

interface FeralinErrorBoundaryState {
  failed: boolean;
  error: unknown;
}

/**
 * Alt ağaçtaki çizim ve yaşam döngüsü hatalarını yakalar, `fr_error` bildirir (`origin: "uncaught_exception"`, `handled: false`) ve
 * `fallback` çizer. İzin, örnekleme, sınır ve PII temizliği Web SDK'nınkidir; ham yığın izi ve bileşen yığını gitmez. Sunucuda
 * (react-dom/server) hiçbir şey göndermez ve pencereye dokunmaz; olay işleyicisi ve zamanlayıcı hataları React sınırına ulaşmaz.
 */
export class FeralinErrorBoundary extends Component<FeralinErrorBoundaryProps, FeralinErrorBoundaryState> {
  static contextType = FeralinContext;
  declare context: ContextType<typeof FeralinContext>;
  state: FeralinErrorBoundaryState = { failed: false, error: undefined };

  static getDerivedStateFromError(error: unknown): FeralinErrorBoundaryState {
    return { failed: true, error };
  }

  componentDidCatch(error: unknown, info: ErrorInfo): void {
    void reportFrameworkError(this.props.feralin ?? this.context ?? ambientFeralin, error, this.props.errors);
    try {
      this.props.onError?.(error, info);
    } catch {
      // Uygulamanın işleyicisi sınırı ikinci kez düşürmez.
    }
  }

  reset = (): void => {
    this.setState({ failed: false, error: undefined });
  };

  render(): ReactNode {
    if (!this.state.failed) return this.props.children;
    const { fallback } = this.props;
    return typeof fallback === "function" ? fallback({ error: this.state.error, reset: this.reset }) : (fallback ?? null);
  }
}
