// @vitest-environment node
// Tauri ön yüzü SSR'li çerçeveyle derlenirken (ör. Next, Nuxt) modül sunucuda da yüklenir.
import { describe, expect, it, vi } from "vitest";
import { createFeralinTauri, isTauri } from "../src/index";

describe("window yok", () => {
  it("patlamaz, istemci ve zamanlayıcı kurmaz", () => {
    expect(typeof window).toBe("undefined");
    const interval = vi.spyOn(globalThis, "setInterval");
    expect(isTauri()).toBe(false);
    const feralin = createFeralinTauri({ projectKey: "pk_test_tauri_ssr_0001", collectUrl: "http://collector.test", allowOutsideTauri: true });
    expect(feralin.active).toBe(false);
    expect(feralin.track("x")).toBeNull();
    expect(interval).not.toHaveBeenCalled();
  });
});
