"use client";
// React bağdaştırıcısı: @feralin/web üstünde Provider ve hook'lar. Sunucu çıktısına DOM eklemez, hydration uyuşmazlığı üretmez.
import { createContext, useContext, useEffect, useMemo, useRef } from "react";
import type { ReactElement, ReactNode } from "react";
import { acquireFeralin, ambientFeralin } from "./handle.js";
import type { Consent, FeralinHandle, FeralinOptions } from "./handle.js";

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
