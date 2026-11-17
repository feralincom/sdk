// Gerçek React ve jsdom; yalnız ağ enjekte edilir. Ana kaynak çekirdeğin kendisidir, sahte istemci yok.
import { StrictMode, act, useEffect } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { FeralinProvider, noopFeralin, releaseFeralin, useFeralin, usePageView } from "../src/index";
import type { FeralinHandle } from "../src/index";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const projectKey = "pk_test_react_unit_0001";
const collectUrl = "http://collector.test";

type Sent = { url: string; headers: Record<string, string>; body: { events: Array<Record<string, any>> } };

function collector(status = 202) {
  const sent: Sent[] = [];
  const fetchImpl = vi.fn(async (url: string, init: RequestInit) => {
    sent.push({ url, headers: init.headers as Record<string, string>, body: JSON.parse(String(init.body)) });
    return new Response(JSON.stringify({ batch_id: "b1", accepted: 1, rejected: 0 }), { status });
  });
  return { sent, fetch: fetchImpl as unknown as typeof fetch };
}

async function mount(element: React.ReactElement) {
  const container = document.createElement("div");
  const root = createRoot(container);
  await act(async () => root.render(element));
  return { root, container };
}

function Capture({ onHandle }: { onHandle: (h: FeralinHandle) => void }) {
  const feralin = useFeralin();
  useEffect(() => {
    onHandle(feralin);
  });
  return null;
}

beforeEach(() => localStorage.clear());
afterEach(() => releaseFeralin({ projectKey, collectUrl }));

describe("FeralinProvider", () => {
  it("izinle page_view üretir ve gerçek /v1/batch isteği atar", async () => {
    const c = collector();
    let feralin!: FeralinHandle;
    await mount(
      <FeralinProvider projectKey={projectKey} collectUrl={collectUrl} fetch={c.fetch} flushIntervalMs={0} consent={{ analytics: true }}>
        <Capture onHandle={(h) => (feralin = h)} />
      </FeralinProvider>,
    );
    expect(feralin.active).toBe(true);
    const event = feralin.track("signup_completed", { plan: "growth" });
    const result = await feralin.flush();
    expect(result.status).toBe(202);
    expect(c.sent).toHaveLength(1);
    expect(c.sent[0]!.url).toBe("http://collector.test/v1/batch");
    expect(c.sent[0]!.headers["x-feralin-project-key"]).toBe(projectKey);
    expect(c.sent[0]!.headers["idempotency-key"]).toMatch(/^[0-9a-f]{16}-2$/);
    expect(c.sent[0]!.body.events.map((e) => e.event_name)).toEqual(["page_view", "signup_completed"]);
    expect(event!.event_id).toMatch(/^[0-9A-Z]{26}$/);
    expect(JSON.stringify(c.sent[0]!.body)).not.toContain("verified");
  });

  it("StrictMode çift çalıştırması tek istemci ve tek page_view üretir", async () => {
    const c = collector();
    let feralin!: FeralinHandle;
    await mount(
      <StrictMode>
        <FeralinProvider projectKey={projectKey} collectUrl={collectUrl} fetch={c.fetch} flushIntervalMs={0} consent={{ analytics: true }}>
          <Capture onHandle={(h) => (feralin = h)} />
        </FeralinProvider>
      </StrictMode>,
    );
    await feralin.flush();
    expect(c.sent[0]!.body.events.filter((e) => e.event_name === "page_view")).toHaveLength(1);
  });

  it("izin yokken olay üretmez ve depoya kimlik yazmaz; izin gelince tek page_view üretir", async () => {
    const c = collector();
    let feralin!: FeralinHandle;
    const tree = (consent: { analytics: boolean }) => (
      <FeralinProvider projectKey={projectKey} collectUrl={collectUrl} fetch={c.fetch} flushIntervalMs={0} consent={consent}>
        <Capture onHandle={(h) => (feralin = h)} />
      </FeralinProvider>
    );
    const { root } = await mount(tree({ analytics: false }));
    expect(feralin.track("order_completed")).toBeNull();
    expect(localStorage.getItem("fr_aid")).toBeNull();
    await feralin.flush();
    expect(c.sent).toHaveLength(0);

    await act(async () => root.render(tree({ analytics: true })));
    expect(localStorage.getItem("fr_aid")).not.toBeNull();
    await feralin.flush();
    expect(c.sent[0]!.body.events.map((e) => e.event_name)).toEqual(["page_view"]);
  });

  it("reklam izni yoksa fr_click çıkarılır, izinle gönderilir", async () => {
    const c = collector();
    let feralin!: FeralinHandle;
    await mount(
      <FeralinProvider projectKey={projectKey} collectUrl={collectUrl} fetch={c.fetch} flushIntervalMs={0} autoTrack={false} consent={{ analytics: true }}>
        <Capture onHandle={(h) => (feralin = h)} />
      </FeralinProvider>,
    );
    expect(feralin.track("order_completed", { fr_click: "clk_1", order_id: "o1" })!.properties).toEqual({ order_id: "o1" });
    feralin.setConsent({ analytics: true, advertising: true });
    expect(feralin.track("order_completed", { fr_click: "clk_2" })!.properties).toEqual({ fr_click: "clk_2" });
  });

  it("401 kuyruğu atar, uygulama düşmez; ağ hatası kuyrukta tutar ve aynı anahtarla yeniden dener", async () => {
    const rejected = collector(401);
    let feralin!: FeralinHandle;
    await mount(
      <FeralinProvider projectKey={projectKey} collectUrl={collectUrl} fetch={rejected.fetch} flushIntervalMs={0} autoTrack={false} consent={{ analytics: true }}>
        <Capture onHandle={(h) => (feralin = h)} />
      </FeralinProvider>,
    );
    feralin.track("order_completed");
    expect((await feralin.flush()).status).toBe(401);
    expect(feralin.getStatus()!.queued).toBe(0);
    releaseFeralin({ projectKey, collectUrl });

    const keys: string[] = [];
    let fail = true;
    const flaky = (async (_url: string, init: RequestInit) => {
      keys.push((init.headers as Record<string, string>)["idempotency-key"]!);
      if (fail) {
        fail = false;
        throw new Error("ağ yok");
      }
      return new Response("{}", { status: 202 });
    }) as unknown as typeof fetch;
    await mount(
      <FeralinProvider projectKey={projectKey} collectUrl={collectUrl} fetch={flaky} flushIntervalMs={0} autoTrack={false} consent={{ analytics: true }}>
        <Capture onHandle={(h) => (feralin = h)} />
      </FeralinProvider>,
    );
    feralin.track("order_completed");
    expect((await feralin.flush()).status).toBe(0);
    expect(feralin.getStatus()!.queued).toBe(1);
    expect((await feralin.flush()).status).toBe(202);
    expect(keys).toHaveLength(2);
    expect(keys[0]).toBe(keys[1]);
  });

  it("serileştirilemeyen özellik kuyruğa girmez, uygulamayı düşürmez", async () => {
    const c = collector();
    let feralin!: FeralinHandle;
    await mount(
      <FeralinProvider projectKey={projectKey} collectUrl={collectUrl} fetch={c.fetch} flushIntervalMs={0} autoTrack={false} consent={{ analytics: true }}>
        <Capture onHandle={(h) => (feralin = h)} />
      </FeralinProvider>,
    );
    expect(feralin.track("order_completed", { big: 1n })).toBeNull();
    expect(feralin.getStatus()!.queued).toBe(0);
  });

  it("trackRevenue feralin_purchase üretir, verified düşer; geçersiz girdi ve serileştirilemeyen özellik null döner", async () => {
    const c = collector();
    let feralin!: FeralinHandle;
    await mount(
      <FeralinProvider projectKey={projectKey} collectUrl={collectUrl} fetch={c.fetch} flushIntervalMs={0} autoTrack={false} consent={{ analytics: true }}>
        <Capture onHandle={(h) => (feralin = h)} />
      </FeralinProvider>,
    );
    const event = feralin.trackRevenue({ transactionId: "tx_1", amountMinor: 4999, currency: "TRY", productId: "pro", properties: { verified: true, plan: "pro" } });
    expect(event!.event_name).toBe("feralin_purchase");
    expect(event!.properties).toEqual({ plan: "pro", transaction_id: "tx_1", amount_minor: 4999, currency: "TRY", quantity: 1, purchase_type: "purchase", product_id: "pro" });
    expect(feralin.trackRevenue({ transactionId: "tx_2", amountMinor: 49.99, currency: "TRY" })).toBeNull();
    expect(feralin.trackRevenue({ transactionId: "tx_3", amountMinor: 1, currency: "TRY", properties: { big: 1n } })).toBeNull();
    expect(feralin.trackRevenue(null as never)).toBeNull();
    expect(noopFeralin.trackRevenue({ transactionId: "tx_4", amountMinor: 1, currency: "TRY" })).toBeNull();
    expect(() => feralin.setReferrer("https://example.com/onceki")).not.toThrow();
    expect(feralin.getStatus()!.queued).toBe(1);
  });

  it("gizli anahtar reddedilir", async () => {
    await expect(mount(<FeralinProvider projectKey="sk_live_gizli_0001" collectUrl={collectUrl} />)).rejects.toThrow(/gizli anahtar/);
  });
});

describe("useFeralin ve usePageView", () => {
  it("Provider ve FeralinScript yoksa boş yüzeye düşer", async () => {
    let feralin!: FeralinHandle;
    await mount(<Capture onHandle={(h) => (feralin = h)} />);
    expect(feralin.active).toBe(false);
    expect(feralin.track("x")).toBeNull();
    expect(noopFeralin.getStatus()).toBeNull();
  });

  it("yol değişince page_view üretir, ilk değeri atlar, aynı değeri tekrarlamaz", async () => {
    const c = collector();
    let feralin!: FeralinHandle;
    function Route({ path }: { path: string }) {
      usePageView(path);
      return null;
    }
    const tree = (path: string) => (
      <StrictMode>
        <FeralinProvider projectKey={projectKey} collectUrl={collectUrl} fetch={c.fetch} flushIntervalMs={0} consent={{ analytics: true }}>
          <Capture onHandle={(h) => (feralin = h)} />
          <Route path={path} />
        </FeralinProvider>
      </StrictMode>
    );
    const { root } = await mount(tree("/a"));
    await act(async () => root.render(tree("/a")));
    await act(async () => root.render(tree("/b")));
    await feralin.flush();
    expect(c.sent[0]!.body.events.filter((e) => e.event_name === "page_view")).toHaveLength(2);
  });
});
