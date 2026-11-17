// FeralinErrorBoundary: gerçek React 19, jsdom ve çekirdek @feralin/web; yalnız ağ enjekte edilir.
import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FeralinErrorBoundary, FeralinProvider, acquireFeralin, releaseFeralin, reportFrameworkError } from "../src/index";
import type { FeralinErrorOptions, FeralinHandle } from "../src/index";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const projectKey = "pk_test_react_errors_01";
const collectUrl = "http://collector.test";

function collector() {
  const events: Array<Record<string, any>> = [];
  const fetchImpl = vi.fn(async (_url: string, init: RequestInit) => {
    events.push(...JSON.parse(String(init.body)).events);
    return new Response(JSON.stringify({ batch_id: "b1", accepted: 1, rejected: 0 }), { status: 202 });
  });
  return { events, fetch: fetchImpl as unknown as typeof fetch };
}

function Boom({ message = "çizim hatası kisi@example.com" }: { message?: string }): never {
  throw new TypeError(message);
}

async function render(element: React.ReactElement) {
  const container = document.createElement("div");
  const root = createRoot(container);
  await act(async () => root.render(element));
  return { root, container };
}

/** Hata modülü dinamik yüklenir: kuyruğa giren olay sayısı beklenene ulaşana kadar beklenir. */
async function settle(feralin: FeralinHandle, queued: number) {
  await vi.waitFor(() => expect(feralin.getStatus()?.queued).toBe(queued));
}

function client(c: ReturnType<typeof collector>, consent = { analytics: true }) {
  return acquireFeralin({ projectKey, collectUrl, fetch: c.fetch, flushIntervalMs: 0, autoTrack: false, consent });
}

beforeEach(() => {
  localStorage.clear();
  // React yakalanan hatayı console.error ile yazar; test çıktısını kirletmesin.
  vi.spyOn(console, "error").mockImplementation(() => {});
});
afterEach(() => {
  releaseFeralin({ projectKey, collectUrl });
  vi.restoreAllMocks();
});

describe("FeralinErrorBoundary", () => {
  it("çizim hatasını yakalar, fallback çizer ve sözleşmeye uygun fr_error gönderir", async () => {
    const c = collector();
    const feralin = client(c);
    const { container } = await render(
      <FeralinProvider projectKey={projectKey} collectUrl={collectUrl}>
        <FeralinErrorBoundary fallback={<p>bir sorun oluştu</p>}>
          <Boom />
        </FeralinErrorBoundary>
      </FeralinProvider>,
    );
    expect(container.textContent).toBe("bir sorun oluştu");
    await settle(feralin, 1);
    await feralin.flush();
    const [event] = c.events;
    expect(event!.event_name).toBe("fr_error");
    const props = event!.properties;
    expect(props).toMatchObject({ error_type: "TypeError", origin: "uncaught_exception", handled: false, fatal: false });
    expect(props.message).toBe("çizim hatası [email]");
    expect(props.fingerprint).toMatch(/^[0-9a-f]{16}$/);
    expect(JSON.stringify(event)).not.toContain("kisi@example.com");
    for (const banned of ["stack", "componentStack"]) expect(props[banned]).toBeUndefined();
    for (const frame of props.frames ?? []) expect(frame.file).not.toMatch(/[\\/]/);
  });

  it("izin yokken olay üretmez ve sınır sayacını harcamaz", async () => {
    const c = collector();
    const feralin = client(c, { analytics: false });
    const options: FeralinErrorOptions = { maxEvents: 1 };
    expect(await reportFrameworkError(feralin, new Error("izinsiz"), options)).toBe(false);
    feralin.setConsent({ analytics: true });
    expect(await reportFrameworkError(feralin, new Error("izinli"), options)).toBe(true);
    await feralin.flush();
    expect(c.events.map((e) => e.properties.message)).toEqual(["izinli"]);
  });

  it("aynı hata nesnesi bir kez, sınır ve örnekleme Web SDK ayarıyla uygulanır", async () => {
    const c = collector();
    const feralin = client(c);
    const error = new Error("tekrar");
    expect(await reportFrameworkError(feralin, error, { maxEvents: 2 })).toBe(true);
    expect(await reportFrameworkError(feralin, error)).toBe(false);
    expect(await reportFrameworkError(feralin, new RangeError("ikinci"))).toBe(true);
    expect(await reportFrameworkError(feralin, new SyntaxError("üçüncü"))).toBe(false);
    await feralin.flush();
    expect(c.events.map((e) => e.properties.error_type)).toEqual(["Error", "RangeError"]);
  });

  it("örnekleme 0 iken olay gitmez", async () => {
    const c = collector();
    const feralin = client(c);
    await render(
      <FeralinErrorBoundary feralin={feralin} errors={{ sampleRate: 0 }} fallback={null}>
        <Boom />
      </FeralinErrorBoundary>,
    );
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(feralin.getStatus()?.queued).toBe(0);
  });

  it("fallback işlevi hatayı ve reset'i alır; reset alt ağacı yeniden çizer; onError hatası yutulur", async () => {
    const c = collector();
    const feralin = client(c);
    const onError = vi.fn(() => {
      throw new Error("uygulama işleyicisi");
    });
    let fail = true;
    function Maybe() {
      const [label] = useState("iyileşti");
      if (fail) throw new Error("geçici");
      return <span>{label}</span>;
    }
    let reset!: () => void;
    const { container } = await render(
      <FeralinErrorBoundary
        feralin={feralin}
        onError={onError}
        fallback={(props) => {
          reset = props.reset;
          return <b>{(props.error as Error).message}</b>;
        }}
      >
        <Maybe />
      </FeralinErrorBoundary>,
    );
    expect(container.textContent).toBe("geçici");
    expect(onError).toHaveBeenCalledOnce();
    fail = false;
    await act(async () => reset());
    expect(container.textContent).toBe("iyileşti");
    await settle(feralin, 1);
  });

  it("Provider yoksa ilk kurulan istemciye gider; istemci yoksa sessizce hiçbir şey yapmaz", async () => {
    const { container } = await render(
      <FeralinErrorBoundary fallback="yedek">
        <Boom />
      </FeralinErrorBoundary>,
    );
    expect(container.textContent).toBe("yedek");
    const c = collector();
    const feralin = client(c);
    await render(
      <FeralinErrorBoundary fallback="yedek">
        <Boom message="ikinci kök" />
      </FeralinErrorBoundary>,
    );
    await settle(feralin, 1);
  });
});
