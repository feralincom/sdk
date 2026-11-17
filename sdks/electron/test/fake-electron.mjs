// Electron kurulu değil: ipcMain, ipcRenderer ve contextBridge'in davranışı Node'da taklit edilir. contextBridge gibi
// yalnız işlev ve yapılandırılmış kopyalanabilir veri geçirir; ipcRenderer invoke gibi argümanları structuredClone ile
// kopyalar. Bu dosya gerçek Electron'un yerine geçmez; README ve kayıt taslağı Electron'da koşmadığını belirtir.
export function fakeElectron({ senderFrame = { url: "app://arayuz/index.html", parent: null } } = {}) {
  const handlers = new Map();
  const ipcMain = {
    handle(channel, listener) {
      if (handlers.has(channel)) throw new Error(`Attempted to register a second handler for '${channel}'`);
      handlers.set(channel, listener);
    },
    removeHandler(channel) {
      handlers.delete(channel);
    },
  };
  const frame = { current: senderFrame };
  const ipcRenderer = {
    async invoke(channel, ...args) {
      const listener = handlers.get(channel);
      if (!listener) throw new Error(`No handler registered for '${channel}'`);
      const result = await listener({ senderFrame: frame.current }, ...structuredClone(args));
      return structuredClone(result);
    },
  };
  const world = {};
  const contextBridge = {
    exposeInMainWorld(key, api) {
      if (key in world) throw new Error(`Cannot bind an API on top of an existing property on the window object: ${key}`);
      for (const [name, value] of Object.entries(api)) {
        if (typeof value !== "function") throw new Error(`köprüde işlev dışı alan: ${name}`);
      }
      world[key] = Object.freeze({ ...api });
    },
  };
  return { ipcMain, ipcRenderer, contextBridge, world, handlers, frame };
}

/** Electron `app` taklidi: olay dinleyicileri, protokol kaydı ve çıkış sayacı. Gerçek işletim sistemi kaydı yapılmaz. */
export function fakeApp({ version = "1.2.3", locale = "tr" } = {}) {
  const listeners = {};
  const protocols = [];
  const app = {
    quits: 0,
    getVersion: () => version,
    getLocale: () => locale,
    on(name, listener) {
      (listeners[name] ??= []).push(listener);
      return app;
    },
    setAsDefaultProtocolClient(scheme) {
      protocols.push(scheme);
      return true;
    },
    quit() {
      app.quits++;
    },
    emit(name, ...args) {
      for (const listener of listeners[name] ?? []) listener(...args);
    },
  };
  return { app, listeners, protocols };
}
