"use client";
// Next.js App Router girişi: sunucu bileşeni olan layout.tsx içine doğrudan konur. Çekirdek uygulamanın kendi istemci
// parçasına paketlenir; dış betik ve CDN gerekmez. Sunucuda istemci kurulmaz, çıktıya hiçbir şey basılmaz.
import { usePathname } from "next/navigation";
import type { ReactElement } from "react";
import { useFeralinClient, usePageView } from "./index.js";
import type { Consent } from "./index.js";

/** Sunucu bileşeninden geçebilen seçenekler; fetch ve storage gibi işlevler sunucu sınırını aşamaz. */
export interface FeralinScriptProps {
  projectKey: string;
  collectUrl: string;
  consent?: Consent;
  autoTrack?: boolean;
  flushIntervalMs?: number;
  batchSize?: number;
  debug?: boolean;
  /** İstemci tarafı yol değişiminde page_view üretir. Varsayılan true. Sorgu dizgisi değişimi yeni sayfa sayılmaz. */
  trackNavigation?: boolean;
}

export function FeralinScript({ trackNavigation = true, ...options }: FeralinScriptProps): ReactElement | null {
  const feralin = useFeralinClient(options);
  const pathname = usePathname();
  usePageView(trackNavigation ? pathname : null, { feralin, skipInitial: options.autoTrack !== false });
  return null;
}
