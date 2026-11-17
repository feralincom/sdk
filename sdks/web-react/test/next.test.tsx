// FeralinScript'in Provider'sız kullanımı: usePathname sahte, React ve çekirdek gerçek. Gerçek Next.js uygulaması
// scripts/sdk-e2e/targets/web-react.mjs içinde derlenir ve tarayıcıda açılır.
import { act, useEffect } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { releaseFeralin, useFeralin } from "../src/index";
import type { FeralinHandle } from "../src/index";
import { FeralinScript } from "../src/next";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

let pathname = "/";
vi.mock("next/navigation", () => ({ usePathname: () => pathname }));

const projectKey = "pk_test_react_next_0001";
const collectUrl = "http://collector.test";

beforeEach(() => {
  localStorage.clear();
  pathname = "/";
});
afterEach(() => releaseFeralin({ projectKey, collectUrl }));

describe("FeralinScript", () => {
  it("DOM eklemez; hook Provider'sız aynı istemciye ulaşır; yol değişiminde page_view üretir", async () => {
    let feralin!: FeralinHandle;
    function Capture() {
      const handle = useFeralin();
      useEffect(() => {
        feralin = handle;
      });
      return null;
    }
    const container = document.createElement("div");
    const root = createRoot(container);
    const tree = () => (
      <>
        <Capture />
        <FeralinScript projectKey={projectKey} collectUrl={collectUrl} flushIntervalMs={0} consent={{ analytics: true }} />
      </>
    );
    await act(async () => root.render(tree()));
    expect(container.innerHTML).toBe("");
    expect(feralin.getStatus()!.queued).toBe(1);

    pathname = "/fiyat";
    await act(async () => root.render(tree()));
    expect(feralin.getStatus()!.queued).toBe(2);
  });

  it("trackNavigation kapalıysa yol değişimi olay üretmez", async () => {
    const root = createRoot(document.createElement("div"));
    let feralin!: FeralinHandle;
    function Capture() {
      const handle = useFeralin();
      useEffect(() => {
        feralin = handle;
      });
      return null;
    }
    const tree = () => (
      <>
        <FeralinScript projectKey={projectKey} collectUrl={collectUrl} flushIntervalMs={0} trackNavigation={false} consent={{ analytics: true }} />
        <Capture />
      </>
    );
    await act(async () => root.render(tree()));
    pathname = "/fiyat";
    await act(async () => root.render(tree()));
    expect(feralin.getStatus()!.queued).toBe(1);
  });
});
