// @vitest-environment node
// window olmadan gerçek Vue SSR; Nuxt evrensel plugin'inin sunucu tarafında yaptığıyla aynı çağrılar.
import { createSSRApp, defineComponent, h } from "vue";
import { renderToString } from "vue/server-renderer";
import { describe, expect, it, vi } from "vitest";
import { FeralinErrorHandler, FeralinPlugin, useFeralin } from "../src/index";

const options = { projectKey: "pk_test_vue_ssr_0001", collectUrl: "http://collector.test", consent: { analytics: true } };

describe("SSR", () => {
  it("ortamda window yok", () => {
    expect(typeof window).toBe("undefined");
    expect(typeof document).toBe("undefined");
  });

  it("hata eklentisi sunucuda olay üretmez, önceki işleyiciyi çağırır", async () => {
    const previous = vi.fn();
    const network = vi.fn();
    const app = createSSRApp(
      defineComponent({
        setup() {
          throw new Error("sunucu hatası");
        },
      }),
    );
    app.config.errorHandler = previous;
    app.use(FeralinPlugin, { ...options, fetch: network as unknown as typeof fetch }).use(FeralinErrorHandler);
    await renderToString(app).catch(() => "");
    expect(previous).toHaveBeenCalledOnce();
    expect(network).not.toHaveBeenCalled();
  });

  it("plugin ve composable sunucuda patlamaz; istemci, zamanlayıcı, ağ yok", async () => {
    const interval = vi.spyOn(globalThis, "setInterval");
    const network = vi.fn();
    const router = { afterEach: vi.fn() };
    const app = createSSRApp(
      defineComponent({
        setup() {
          const feralin = useFeralin();
          return () => h("p", String(feralin.active) + String(feralin.track("server_side")));
        },
      }),
    );
    app.use(FeralinPlugin, { ...options, fetch: network as unknown as typeof fetch, router });
    expect(await renderToString(app)).toBe("<p>falsenull</p>");
    expect(interval).not.toHaveBeenCalled();
    expect(network).not.toHaveBeenCalled();
    expect(router.afterEach).not.toHaveBeenCalled();
    interval.mockRestore();
  });

  it("istek başına iki uygulama aynı boş yüzeyi paylaşır, durum tutmaz", async () => {
    for (let i = 0; i < 2; i++) {
      const app = createSSRApp(defineComponent({ render: () => h("div") }));
      app.use(FeralinPlugin, options);
      expect(app.config.globalProperties.$feralin.getStatus()).toBeNull();
    }
  });

  it("gizli anahtar sunucuda da reddedilir", () => {
    const app = createSSRApp(defineComponent({ render: () => h("div") }));
    expect(() => FeralinPlugin.install(app, { ...options, projectKey: "sk_live_gizli_0001" })).toThrow(/gizli anahtar/);
  });

  it("yalnız pk_ kabul edilir; boşluk ve büyük harf kara listeyi aşamaz", () => {
    const app = createSSRApp(defineComponent({ render: () => h("div") }));
    for (const bad of [" sk_live_gizli_0001", "SK_LIVE_GIZLI_0001"]) expect(() => FeralinPlugin.install(app, { ...options, projectKey: bad })).toThrow(/gizli anahtar/);
    expect(() => FeralinPlugin.install(app, { ...options, projectKey: "rk_live_gizli_0001" })).toThrow(/pk_/);
  });
});
