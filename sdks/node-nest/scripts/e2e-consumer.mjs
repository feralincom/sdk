// Temiz kurulumdan çalışan tüketici: gerçek NestJS uygulaması, gerçek HTTP, gerçek services/collect. Dekoratörler elle uygulanır.
import "reflect-metadata";
import assert from "node:assert/strict";
import { createRequire } from "node:module";
import { Body, Controller, Module, Post } from "@nestjs/common";
import { NestFactory } from "@nestjs/core";
import { CurrentFeralin, FeralinModule } from "@feralin/nest";
import { env, runServerScenarios } from "./server-scenarios.mjs";

assert.equal(typeof createRequire(import.meta.url)("@feralin/nest").FeralinModule.forRoot, "function");
console.log("  OK cjs-esm");

const { collectUrl } = env();

async function start({ projectKey, fetch: fetchImpl }) {
  class Events {
    async create(feralin, body) {
      const event = feralin.track(body.name, body.properties);
      return { event, flush: await feralin.flush() };
    }
  }
  Post("olay")(Events.prototype, "create", Object.getOwnPropertyDescriptor(Events.prototype, "create"));
  CurrentFeralin()(Events.prototype, "create", 0);
  Body()(Events.prototype, "create", 1);
  Controller()(Events);
  class AppModule {}
  Module({
    imports: [
      FeralinModule.forRoot({
        projectKey,
        collectUrl,
        flushIntervalMs: 0,
        ...(fetchImpl ? { fetch: fetchImpl } : {}),
        resolveConsent: (req) => ({ analytics: req.headers["x-izin"] === "evet", advertising: req.headers["x-reklam"] === "evet" }),
      }),
    ],
    controllers: [Events],
  })(AppModule);
  const app = await NestFactory.create(AppModule, { logger: false });
  await app.listen(0, "127.0.0.1");
  return { base: await app.getUrl(), close: () => app.close() };
}

await runServerScenarios({ start, label: "nest" });
console.log("nest tüketici: tüm senaryolar geçti");
process.exit(0);
