// @feralin/capacitor: Capacitor eklentisi. Android'de `FeralinPlugin.java` (Feralin Android AAR), iOS'ta `FeralinPlugin.swift`
// (Feralin Swift çekirdeği), tarayıcıda @feralin/web yedeği çalışır. Uygulama yalnız `Feralin` nesnesini kullanır.
import { registerPlugin } from "@capacitor/core";

import { createFeralin } from "./core.js";
import type { NativeFeralin } from "./definitions.js";

const native = registerPlugin<NativeFeralin>("Feralin", {
  web: () => import("./web-native.js").then((module) => module.createWebNative(() => import("@feralin/web"))),
});

export const Feralin = createFeralin(native);
export default Feralin;

export { SDK_NAME, SDK_VERSION, buildRevenueProperties, createFeralin, isUninstallCheck, normalizeConfig, sanitizeProperties } from "./core.js";
export type * from "./definitions.js";
