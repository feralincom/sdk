// Temiz kurulumdan çalışan tüketici. Vue DOM nesnesini yükleme anında okur; bu yüzden iki ayrı süreç koşar:
// `ssr`: window yokken gerçek Vue SSR. Argümansız: jsdom üzerinde plugin ve gerçek services/collect.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { env, installDom, runWebScenarios } from "./web-scenarios.mjs";

const { collectUrl, projectKey } = env();

if (process.argv[2] === "ssr") {
  assert.equal(typeof window, "undefined");
  const { createSSRApp, defineComponent, h } = await import("vue");
  const { renderToString } = await import("vue/server-renderer");
  const { FeralinPlugin } = await import("@feralin/vue");
  const cjs = createRequire(import.meta.url)("@feralin/vue");
  assert.equal(typeof cjs.FeralinPlugin.install, "function");
  console.log("  OK cjs-esm");
  const ssr = createSSRApp(defineComponent({ render: () => h("p", "ssr") }));
  ssr.use(FeralinPlugin, { projectKey, collectUrl, consent: { analytics: true } });
  assert.equal(await renderToString(ssr), "<p>ssr</p>");
  console.log("  OK ssr-window-yok");
  process.exit(0);
}

installDom();
const { createApp, defineComponent, h } = await import("vue");
const { FeralinPlugin, releaseFeralin, useFeralin } = await import("@feralin/vue");

async function mount(options) {
  let captured;
  const app = createApp(
    defineComponent({
      setup() {
        captured = useFeralin();
        return () => h("div");
      },
    }),
  );
  app.use(FeralinPlugin, options);
  app.mount(document.createElement("div"));
  return captured;
}

await runWebScenarios({ mount, release: async (options) => releaseFeralin(options), label: "vue" });
console.log("vue tüketici: tüm senaryolar geçti");
process.exit(0);
