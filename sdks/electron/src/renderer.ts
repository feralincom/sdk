// Web görünümü tarafı: preload'ın açtığı köprüye türlü erişim. Köprü yoksa (tarayıcıda geliştirme, SSR) boş yüzey döner.
import type { FeralinBridge } from "./channels.js";

export type { BridgeErrorPayload, BridgeRevenueInput, FeralinBridge } from "./channels.js";

export const noopFeralinBridge: FeralinBridge = Object.freeze({
  track: () => Promise.resolve(false),
  page: () => Promise.resolve(false),
  identify: () => Promise.resolve(),
  setConsent: () => Promise.resolve(),
  reset: () => Promise.resolve(),
  flush: () => Promise.resolve({ status: 0, accepted: 0, rejected: 0, retained: 0 }),
  trackRevenue: () => Promise.resolve(false),
  group: () => Promise.resolve(false),
  setUserProperties: () => Promise.resolve(false),
  captureError: () => Promise.resolve(false),
});

export function getFeralin(key: string = "feralin"): FeralinBridge {
  const bridge = typeof window === "undefined" ? undefined : (window as unknown as Record<string, FeralinBridge | undefined>)[key];
  return bridge ?? noopFeralinBridge;
}
