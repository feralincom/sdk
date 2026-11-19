import { NativeModules, Platform } from "react-native";
import { createFeralin } from "./core";
import type { ErrorUtilsLike, NativeBridge, UncaughtErrorOptions } from "./core";

export { SDK_NAME, SDK_VERSION } from "./core";
export type {
  Consent,
  DeferredDeepLink,
  ShortLinkOpen,
  FeralinApi,
  FeralinConfig,
  FeralinStatus,
  FlushResult,
  InstallBinding,
  PurchaseType,
  ReceiptProvider,
  RevenueInput,
  AdFormat,
  AdPrecision,
  AdRevenueInput,
  EconomyOptions,
  LevelOptions,
  UncaughtErrorOptions,
} from "./core";

// iOS'ta modül yoktur: SDK kapalı kalır, uygulama düşmez, getStatus nedeni bildirir (BLOCKED_EXTERNAL).
const api = createFeralin(NativeModules.FeralinReactNative as NativeBridge | undefined, Platform.OS);

/** İşlenmemiş Promise reddi izleyicisi: Hermes yerleşik izleyicisi, yoksa RN'in `promise` çok katmanlısı. Açılamazsa `false`. */
function trackRejections(onUnhandled: (reason: unknown) => void): boolean {
  const g = globalThis as unknown as {
    HermesInternal?: { hasPromise?: () => boolean; enablePromiseRejectionTracker?: (options: unknown) => void };
  };
  const hermes = g.HermesInternal;
  if (hermes?.hasPromise?.() && typeof hermes.enablePromiseRejectionTracker === "function") {
    hermes.enablePromiseRejectionTracker({ allRejections: true, onUnhandled: (_id: unknown, reason: unknown) => onUnhandled(reason) });
    return true;
  }
  try {
    // eslint-disable-next-line @typescript-eslint/no-require-imports
    const tracking = require("promise/setimmediate/rejection-tracking");
    tracking.enable({ allRejections: true, onUnhandled: (_id: unknown, reason: unknown) => onUnhandled(reason) });
    return true;
  } catch {
    return false;
  }
}

const Feralin = {
  ...api,
  // Çekirdek RN'e bağlı değildir; çalışma zamanı bağlantıları burada verilir.
  captureUncaughtErrors(options?: UncaughtErrorOptions): boolean {
    const g = globalThis as unknown as { ErrorUtils?: ErrorUtilsLike; __DEV__?: boolean };
    return api.captureUncaughtErrors(options, { errorUtils: g.ErrorUtils, trackRejections, dev: g.__DEV__ === true });
  },
};

export default Feralin;
