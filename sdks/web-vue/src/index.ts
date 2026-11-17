// Vue 3 bağdaştırıcısı: @feralin/web üstünde plugin ve composable. Nuxt'ta sunucu tarafında da kurulabilir; sunucuda
// istemci, zamanlayıcı ve istekler arası paylaşılan durum oluşmaz.
import { hasInjectionContext, inject } from "vue";
import type { App, InjectionKey } from "vue";
import { acquireFeralin, ambientFeralin } from "./handle.js";
import type { FeralinHandle, FeralinOptions } from "./handle.js";

export { acquireFeralin, noopFeralin, releaseFeralin } from "./handle.js";
export type { Consent, FeralinHandle, FeralinOptions, FeralinStatus, FlushResult, RevenueInput, UtpEvent } from "./handle.js";

export const FERALIN_KEY: InjectionKey<FeralinHandle> = Symbol("feralin");

/** vue-router'a çalışma zamanı bağımlılığı olmasın: yalnız afterEach gerekir. */
export interface FeralinRouterLike {
  afterEach(guard: (to: { path: string }, from: { path: string; matched?: readonly unknown[] }, failure?: unknown) => unknown): unknown;
}

export interface FeralinPluginOptions extends FeralinOptions {
  /** Verilirse yol değişiminde page_view üretilir; sorgu dizgisi değişimi yeni sayfa sayılmaz. */
  router?: FeralinRouterLike;
}

declare module "vue" {
  interface ComponentCustomProperties {
    $feralin: FeralinHandle;
  }
}

export const FeralinPlugin = {
  install(app: App, { router, ...options }: FeralinPluginOptions): void {
    const feralin = acquireFeralin(options);
    app.provide(FERALIN_KEY, feralin);
    app.config.globalProperties.$feralin = feralin;
    if (router && feralin.active) {
      router.afterEach((to, from, failure) => {
        // İptal edilen veya tekrarlanan gezinme sayfa değiştirmez.
        if (failure) return;
        // İlk gezinmede `from` START_LOCATION'dır (matched boş): çekirdeğin autoTrack'i o sayfayı zaten gönderir.
        const initial = !from.matched || from.matched.length === 0;
        if (initial && options.autoTrack !== false) return;
        if (!initial && to.path === from.path) return;
        feralin.page();
      });
    }
  },
};

/** Bileşen, Pinia veya Nuxt bağlamında plugin'in istemcisini; bağlam dışında ilk kurulan istemciyi verir. Sunucuda boş yüzeydir. */
export function useFeralin(): FeralinHandle {
  return (hasInjectionContext() ? inject(FERALIN_KEY, null) : null) ?? ambientFeralin;
}
