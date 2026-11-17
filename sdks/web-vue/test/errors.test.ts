// FeralinErrorHandler: gerçek Vue 3, jsdom ve çekirdek @feralin/web; yalnız ağ enjekte edilir.
import { readFileSync } from "node:fs";
import { createApp, defineComponent, h, nextTick } from "vue";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FeralinErrorHandler, FeralinPlugin, releaseFeralin, useFeralin } from "../src/index";
import type { FeralinHandle } from "../src/index";

const projectKey = "pk_test_vue_errors_01";
const collectUrl = "http://collector.test";

function collector() {
  const events: Array<Record<string, any>> = [];
  const fetchImpl = vi.fn(async (_url: string, init: RequestInit) => {
    events.push(...JSON.parse(String(init.body)).events);
    return new Response(JSON.stringify({ batch_id: "b1" }), { status: 202 });
  });
  return { events, fetch: fetchImpl as unknown as typeof fetch };
}

const Boom = defineComponent({
  setup() {
    throw new TypeError("bileşen hatası ayse@example.com");
  },
});

function mount(order: "plugin-first" | "handler-first", extra: Record<string, unknown> = {}, previous?: (...args: unknown[]) => void) {
  const c = collector();
  let feralin!: FeralinHandle;
  const app = createApp(
    defineComponent({
      setup() {
        feralin = useFeralin();
        return () => h("div", [h(Boom)]);
      },
    }),
  );
  if (previous) app.config.errorHandler = previous;
  const plugin = { projectKey, collectUrl, flushIntervalMs: 0, autoTrack: false, fetch: c.fetch, consent: { analytics: true }, ...extra };
  if (order === "plugin-first") app.use(FeralinPlugin, plugin as never).use(FeralinErrorHandler);
  else app.use(FeralinErrorHandler).use(FeralinPlugin, plugin as never);
  app.mount(document.createElement("div"));
  return { c, app, feralin };
}

async function settle(feralin: FeralinHandle, queued: number) {
  await vi.waitFor(() => expect(feralin.getStatus()?.queued).toBe(queued));
}

beforeEach(() => localStorage.clear());
afterEach(() => {
  releaseFeralin({ projectKey, collectUrl });
  vi.restoreAllMocks();
});

describe("FeralinErrorHandler", () => {
  it("bileşen hatasını fr_error olarak gönderir; mevcut işleyici aynı argümanlarla çağrılır", async () => {
    const previous = vi.fn();
    const { c, feralin } = mount("plugin-first", {}, previous);
    expect(previous).toHaveBeenCalledOnce();
    expect(previous.mock.calls[0]![0]).toBeInstanceOf(TypeError);
    expect(typeof previous.mock.calls[0]![2]).toBe("string");
    await settle(feralin, 1);
    await feralin.flush();
    const props = c.events[0]!.properties;
    expect(c.events[0]!.event_name).toBe("fr_error");
    expect(props).toMatchObject({ error_type: "TypeError", origin: "uncaught_exception", handled: false, fatal: false, message: "bileşen hatası [email]" });
    expect(JSON.stringify(c.events)).not.toContain("ayse@");
    expect(props.stack).toBeUndefined();
  });

  it("eklenti sırası önemsiz; önceki işleyici yoksa console.error", async () => {
    const logged = vi.spyOn(console, "error").mockImplementation(() => {});
    const { feralin } = mount("handler-first");
    expect(logged).toHaveBeenCalledOnce();
    await settle(feralin, 1);
  });

  it("izin yokken olay üretmez; işleyici yine çağrılır", async () => {
    const previous = vi.fn();
    const { feralin } = mount("plugin-first", { consent: { analytics: false } }, previous);
    expect(previous).toHaveBeenCalledOnce();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(feralin.getStatus()?.queued).toBe(0);
  });

  it("örnekleme ve sınır seçenekleri Web SDK'ya iletilir", async () => {
    const c = collector();
    const app = createApp(defineComponent({ render: () => h("div") }));
    app.config.errorHandler = () => {};
    app.use(FeralinPlugin, { projectKey, collectUrl, flushIntervalMs: 0, autoTrack: false, fetch: c.fetch, consent: { analytics: true } } as never);
    app.use(FeralinErrorHandler, { maxEvents: 1 });
    app.mount(document.createElement("div"));
    const handler = app.config.errorHandler!;
    handler(new Error("bir"), null, "test");
    handler(new Error("iki"), null, "test");
    await nextTick();
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(app.runWithContext(() => useFeralin()).getStatus()?.queued).toBe(1);
  });

  it("ortak hata katmanı web-react ile birebir aynı", () => {
    expect(readFileSync("src/errors.ts", "utf8")).toBe(readFileSync("../web-react/src/errors.ts", "utf8"));
  });
});
