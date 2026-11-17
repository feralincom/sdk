// Temiz kurulumdan çalışan tüketici. Önce window yokken gerçek SSR, sonra jsdom üzerinde Provider ve gerçek services/collect.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { createElement, useEffect } from "react";
import { renderToString } from "react-dom/server";
import { FeralinProvider, releaseFeralin, useFeralin } from "@feralin/react";
import { env, installDom, runWebScenarios } from "./web-scenarios.mjs";

const cjs = createRequire(import.meta.url)("@feralin/react");
assert.equal(typeof cjs.FeralinProvider, "function");
console.log("  OK cjs-esm");

const { collectUrl, projectKey } = env();
assert.equal(typeof window, "undefined");
const html = renderToString(
  createElement(FeralinProvider, { projectKey, collectUrl, consent: { analytics: true } }, createElement("p", null, "ssr")),
);
assert.equal(html, "<p>ssr</p>");
console.log("  OK ssr-window-yok");

installDom();
globalThis.IS_REACT_ACT_ENVIRONMENT = true;
const { act } = await import("react");
const { createRoot } = await import("react-dom/client");
const roots = [];

async function mount(options) {
  let captured;
  function Capture() {
    const feralin = useFeralin();
    useEffect(() => {
      captured = feralin;
    });
    return null;
  }
  const root = createRoot(document.getElementById("app").appendChild(document.createElement("div")));
  roots.push(root);
  await act(async () => root.render(createElement(FeralinProvider, options, createElement(Capture))));
  return captured;
}

await runWebScenarios({ mount, release: async (options) => releaseFeralin(options), label: "react" });
for (const root of roots) await act(async () => root.unmount());
console.log("react tüketici: tüm senaryolar geçti");
process.exit(0);
