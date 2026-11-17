// Preload tarafı: contextIsolation açıkken web görünümüne yalnız dar bir yüzey açar; ipcRenderer dışarı verilmez.
// sandbox: true preload'lar npm paketi yükleyemez, bu dosya uygulamanın preload paketine katılmalıdır (README).
import { FERALIN_CHANNELS } from "./channels.js";
import type { BridgeErrorPayload, FeralinBridge } from "./channels.js";

export { FERALIN_CHANNELS } from "./channels.js";
export type { BridgeErrorPayload, BridgeRevenueInput, FeralinBridge } from "./channels.js";

export interface ContextBridgeLike {
  exposeInMainWorld(key: string, api: unknown): void;
}

export interface IpcRendererLike {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- Electron ipcRenderer.invoke imzasıyla uyum
  invoke(channel: string, ...args: unknown[]): Promise<any>;
}

export const DEFAULT_BRIDGE_KEY = "feralin";

/** Error nesnesi IPC'de güvenilir biçimde kopyalanmaz: yalnız dizge alanları alınır. Doğrulama ve kırpma ana süreçtedir. */
function toErrorPayload(error: unknown): BridgeErrorPayload {
  if (typeof error === "string") return { message: error };
  if (error && typeof error === "object") {
    const e = error as { name?: unknown; message?: unknown; stack?: unknown };
    const out: BridgeErrorPayload = {};
    if (typeof e.name === "string") out.name = e.name;
    if (typeof e.message === "string") out.message = e.message;
    if (typeof e.stack === "string") out.stack = e.stack;
    return out;
  }
  return error === undefined || error === null ? {} : { message: String(error) };
}

export function createFeralinBridge(ipcRenderer: IpcRendererLike): FeralinBridge {
  return {
    track: (eventName, properties) => ipcRenderer.invoke(FERALIN_CHANNELS.track, eventName, properties),
    page: (properties) => ipcRenderer.invoke(FERALIN_CHANNELS.page, properties),
    identify: (userId) => ipcRenderer.invoke(FERALIN_CHANNELS.identify, userId),
    setConsent: (consent) => ipcRenderer.invoke(FERALIN_CHANNELS.setConsent, consent),
    reset: () => ipcRenderer.invoke(FERALIN_CHANNELS.reset),
    flush: () => ipcRenderer.invoke(FERALIN_CHANNELS.flush),
    trackRevenue: (input) => ipcRenderer.invoke(FERALIN_CHANNELS.trackRevenue, input),
    group: (groupId, traits) => ipcRenderer.invoke(FERALIN_CHANNELS.group, groupId, traits),
    setUserProperties: (properties) => ipcRenderer.invoke(FERALIN_CHANNELS.setUserProperties, properties),
    captureError: (error, options) => ipcRenderer.invoke(FERALIN_CHANNELS.captureError, toErrorPayload(error), options?.origin),
  };
}

export function exposeFeralin(deps: { contextBridge: ContextBridgeLike; ipcRenderer: IpcRendererLike }, key: string = DEFAULT_BRIDGE_KEY): void {
  deps.contextBridge.exposeInMainWorld(key, createFeralinBridge(deps.ipcRenderer));
}
