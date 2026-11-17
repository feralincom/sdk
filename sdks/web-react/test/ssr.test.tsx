// @vitest-environment node
// window ve document olmadan: react-dom/server gerçek olarak render eder; istemci kurulmaz, zamanlayıcı açılmaz.
import { renderToString } from "react-dom/server";
import { afterEach, describe, expect, it, vi } from "vitest";
import { FeralinProvider, useFeralin, usePageView } from "../src/index";
import { FeralinScript } from "../src/next";

vi.mock("next/navigation", () => ({ usePathname: () => "/fiyat" }));

const projectKey = "pk_test_react_ssr_0001";
const collectUrl = "http://collector.test";

afterEach(() => vi.restoreAllMocks());

function Child() {
  const feralin = useFeralin();
  usePageView("/fiyat");
  return <p>{String(feralin.track("server_side") === null)}</p>;
}

describe("SSR", () => {
  it("ortamda window yok", () => {
    expect(typeof window).toBe("undefined");
    expect(typeof document).toBe("undefined");
  });

  it("Provider sunucuda patlamaz, DOM eklemez, istemci ve zamanlayıcı kurmaz, ağ çağırmaz", () => {
    const interval = vi.spyOn(globalThis, "setInterval");
    const network = vi.fn();
    const html = renderToString(
      <FeralinProvider projectKey={projectKey} collectUrl={collectUrl} fetch={network as unknown as typeof fetch} consent={{ analytics: true }}>
        <Child />
      </FeralinProvider>,
    );
    expect(html).toBe("<p>true</p>");
    expect(interval).not.toHaveBeenCalled();
    expect(network).not.toHaveBeenCalled();
  });

  it("FeralinScript sunucuda boş çıktı verir", () => {
    const interval = vi.spyOn(globalThis, "setInterval");
    expect(renderToString(<FeralinScript projectKey={projectKey} collectUrl={collectUrl} consent={{ analytics: true }} />)).toBe("");
    expect(interval).not.toHaveBeenCalled();
  });

  it("gizli anahtar sunucuda da reddedilir", () => {
    expect(() => renderToString(<FeralinProvider projectKey="sk_live_gizli_0001" collectUrl={collectUrl} />)).toThrow(/gizli anahtar/);
  });

  it("yalnız pk_ kabul edilir; boşluk ve büyük harf kara listeyi aşamaz", () => {
    for (const bad of [" sk_live_gizli_0001", "SK_LIVE_GIZLI_0001"]) expect(() => renderToString(<FeralinProvider projectKey={bad} collectUrl={collectUrl} />)).toThrow(/gizli anahtar/);
    expect(() => renderToString(<FeralinProvider projectKey="rk_live_gizli_0001" collectUrl={collectUrl} />)).toThrow(/pk_/);
  });
});
