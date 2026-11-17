// Temiz kurulumdan çalışan tüketici: gerçek Express uygulaması, gerçek HTTP, gerçek services/collect.
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import express from "express";
import { feralinMiddleware } from "@feralin/express";
import { env, runServerScenarios } from "./server-scenarios.mjs";

assert.equal(typeof createRequire(import.meta.url)("@feralin/express").feralinMiddleware, "function");
console.log("  OK cjs-esm");

const { collectUrl } = env();

async function start({ projectKey, fetch: fetchImpl }) {
  const app = express();
  const middleware = feralinMiddleware({
    projectKey,
    collectUrl,
    flushIntervalMs: 0,
    ...(fetchImpl ? { fetch: fetchImpl } : {}),
    resolveConsent: (req) => ({ analytics: req.get("x-izin") === "evet", advertising: req.get("x-reklam") === "evet" }),
  });
  app.use(express.json());
  app.use(middleware);
  app.post("/olay", async (req, res) => {
    const event = req.feralin.track(req.body.name, req.body.properties);
    res.json({ event, flush: await req.feralin.flush() });
  });
  const server = await new Promise((resolve) => {
    const s = app.listen(0, "127.0.0.1", () => resolve(s));
  });
  return {
    base: `http://127.0.0.1:${server.address().port}`,
    close: async () => {
      await new Promise((resolve) => server.close(resolve));
      await middleware.close();
    },
  };
}

await runServerScenarios({ start, label: "express" });
console.log("express tüketici: tüm senaryolar geçti");
process.exit(0);
