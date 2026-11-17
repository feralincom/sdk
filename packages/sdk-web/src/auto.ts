// Feralin Web SDK — otomatik olay modülü (K6, ayrı giriş noktası, çekirdek bütçesine girmez).
// Her davranış ayrı açılıp kapanır. Olaylar çekirdek örnekten geçer: izin (`consent.analytics`) yokken hiçbir olay üretilmez,
// izin geri çekilince modül aynı anda susar. Sorgu dizgisi ve parça hiçbir olaya girmez; parmak izi çıkarılmaz.
//   page_view          tek sayfalı uygulamada rota değişimi (History API: pushState, replaceState, popstate)
//   fr_outbound_click  {link_host}                       başka alan adına giden bağlantı
//   fr_file_download   {file_extension, file_name}       izinli uzantılı dosya bağlantısı
//   fr_not_found       {}                                sayfa 404 olarak işaretliyse (meta etiketi ya da işlev)
//   fr_site_search     {search_term, search_param}       site içi arama parametresi (varsayılan KAPALI: metin kişisel veri taşıyabilir)
import type { Consent } from "./types";

/** Çekirdek SDK'nın modülün gördüğü yüzü; test için sahte örnek verilebilir. */
export interface AutoClient {
  track(eventName: string, properties?: Record<string, unknown>): unknown;
  page(properties?: Record<string, unknown>): unknown;
  getStatus(): { consent: Consent } | null;
  /** İsteğe bağlı: SPA'da önceki sayfa adresi yönlendiren olarak verilir. */
  setReferrer?(url?: string): void;
}

export interface AutoOptions {
  client: AutoClient;
  /** Rota değişiminde page_view (varsayılan true). */
  spa?: boolean;
  /** Dış bağlantı tıklaması (varsayılan true). */
  outbound?: boolean;
  /** Dosya indirme: true varsayılan uzantılar, dizi verilirse yalnız o uzantılar (varsayılan true). */
  downloads?: boolean | readonly string[];
  /** 404 işaretleme: true meta etiketi ve başlık sezgisi, işlev verilirse onun sonucu (varsayılan true). */
  notFound?: boolean | (() => boolean);
  /** Site içi arama: true varsayılan parametreler, dizi verilirse yalnız o parametreler (varsayılan false). */
  siteSearch?: boolean | readonly string[];
  /** Test/SSR için enjekte edilebilir belge, pencere ve zamanlayıcı. */
  document?: Document;
  window?: Window;
}

export interface AutoHandle {
  stop(): void;
}

export const AUTO_EVENT_OUTBOUND = "fr_outbound_click";
export const AUTO_EVENT_DOWNLOAD = "fr_file_download";
export const AUTO_EVENT_NOT_FOUND = "fr_not_found";
export const AUTO_EVENT_SEARCH = "fr_site_search";

export const DEFAULT_DOWNLOAD_EXTENSIONS: readonly string[] = ["pdf", "zip", "rar", "7z", "gz", "dmg", "exe", "msi", "apk", "ipa", "csv", "xls", "xlsx", "doc", "docx", "ppt", "pptx", "mp3", "mp4", "mov"];
export const DEFAULT_SEARCH_PARAMS: readonly string[] = ["q", "s", "search", "query", "keyword"];
const MAX_TERM_LENGTH = 100;
const MAX_NAME_LENGTH = 100;
/** Rota değişiminden sonra başlığın ve 404 işaretinin güncellenmesi için kısa bekleme. */
const ROUTE_SETTLE_MS = 50;

function parseHttp(href: string, base: string): URL | null {
  try {
    const u = new URL(href, base);
    return u.protocol === "http:" || u.protocol === "https:" ? u : null;
  } catch {
    return null;
  }
}

function extensionOf(pathname: string): { ext: string; name: string } {
  const last = pathname.split("/").pop() ?? "";
  const dot = last.lastIndexOf(".");
  return { ext: dot > 0 ? last.slice(dot + 1).toLowerCase() : "", name: last.slice(0, MAX_NAME_LENGTH) };
}

/** Varsayılan 404 sezgisi: açık işaret (meta) ya da başlıkta tek başına "404". */
function looksNotFound(doc: Document): boolean {
  const meta = doc.querySelector?.('meta[name="feralin:status"], meta[name="prerender-status-code"]');
  const content = meta?.getAttribute("content")?.trim();
  if (content) return content === "404";
  return /(^|[^0-9])404([^0-9]|$)/.test(doc.title ?? "");
}

export function startAutoEvents(options: AutoOptions): AutoHandle {
  const doc = options.document ?? (typeof document !== "undefined" ? document : undefined);
  const win = options.window ?? (typeof window !== "undefined" ? window : undefined);
  const noop: AutoHandle = { stop() {} };
  if (!doc || !win) return noop;
  const { client } = options;
  const spa = options.spa !== false;
  const outbound = options.outbound !== false;
  const downloads = options.downloads === undefined || options.downloads === true ? DEFAULT_DOWNLOAD_EXTENSIONS : options.downloads === false ? null : options.downloads.map((e) => e.toLowerCase().replace(/^\./, ""));
  const notFound = options.notFound === undefined ? true : options.notFound;
  const searchParams = options.siteSearch === true ? DEFAULT_SEARCH_PARAMS : options.siteSearch ? options.siteSearch : null;

  /** İzin her olayda yeniden okunur: geri çekilince modül aynı anda susar. */
  const allowed = (): boolean => client.getStatus()?.consent.analytics === true;
  const here = (): URL | null => parseHttp(win.location.href, win.location.href);

  let lastHref = win.location.href;
  let lastPath = win.location.pathname;
  let settle: ReturnType<typeof setTimeout> | undefined;
  const timeouts = new Set<ReturnType<typeof setTimeout>>();

  /** Sayfa başına bir kez: 404 işareti ve site içi arama. Dedup anahtarı yol + sorgu. */
  const reported = new Set<string>();
  const inspectPage = (): void => {
    if (!allowed()) return;
    const url = here();
    if (!url) return;
    const key = url.pathname + url.search;
    if (reported.has(key)) return;
    reported.add(key);
    if (notFound && (typeof notFound === "function" ? notFound() : looksNotFound(doc))) client.track(AUTO_EVENT_NOT_FOUND);
    if (searchParams) {
      for (const param of searchParams) {
        const term = url.searchParams.get(param)?.trim();
        if (term) {
          client.track(AUTO_EVENT_SEARCH, { search_term: term.slice(0, MAX_TERM_LENGTH), search_param: param });
          break;
        }
      }
    }
  };

  const onRouteChange = (): void => {
    const next = win.location.href;
    if (next === lastHref) return;
    const previous = lastHref;
    const pathChanged = win.location.pathname !== lastPath;
    lastHref = next;
    lastPath = win.location.pathname;
    if (settle) {
      clearTimeout(settle);
      timeouts.delete(settle);
    }
    const timer = setTimeout(() => {
      timeouts.delete(timer);
      if (!allowed()) return;
      // Yalnız yol değiştiyse sayfa görüntüleme sayılır; aynı yolda sorgu ya da parça değişimi (filtre, sekme) yeni sayfa değildir.
      if (spa && pathChanged) {
        client.setReferrer?.(previous);
        client.page();
      }
      inspectPage();
    }, ROUTE_SETTLE_MS);
    settle = timer;
    timeouts.add(timer);
  };

  // History API sarmalayıcıları: özgün işlev her zaman çağrılır, durdurulunca geri konur.
  const history = win.history;
  const originalPush = history?.pushState;
  const originalReplace = history?.replaceState;
  let patched = false;
  if (history && typeof originalPush === "function" && typeof originalReplace === "function") {
    patched = true;
    history.pushState = function (this: History, ...args: Parameters<History["pushState"]>) {
      const result = originalPush.apply(this, args);
      onRouteChange();
      return result;
    };
    history.replaceState = function (this: History, ...args: Parameters<History["replaceState"]>) {
      const result = originalReplace.apply(this, args);
      onRouteChange();
      return result;
    };
  }
  const onPopState = (): void => onRouteChange();
  win.addEventListener("popstate", onPopState);

  const onClick = (event: Event): void => {
    if (!outbound && !downloads) return;
    if (!allowed()) return;
    const target = event.target as Element | null;
    const anchor = target?.closest?.("a[href]");
    const href = anchor?.getAttribute("href");
    if (!anchor || !href) return;
    const link = parseHttp(href, win.location.href);
    if (!link) return;
    if (downloads) {
      const { ext, name } = extensionOf(link.pathname);
      if (ext && downloads.includes(ext)) {
        client.track(AUTO_EVENT_DOWNLOAD, { file_extension: ext, file_name: name });
        return;
      }
    }
    if (outbound && link.host !== win.location.host) client.track(AUTO_EVENT_OUTBOUND, { link_host: link.hostname });
  };
  doc.addEventListener("click", onClick, true);

  // İlk sayfa: çekirdek autoTrack page_view'ı kendisi üretir; burada yalnız 404 ve arama işaretlenir.
  const initial = setTimeout(() => {
    timeouts.delete(initial);
    inspectPage();
  }, ROUTE_SETTLE_MS);
  timeouts.add(initial);

  return {
    stop() {
      doc.removeEventListener("click", onClick, true);
      win.removeEventListener("popstate", onPopState);
      if (patched && history) {
        history.pushState = originalPush as History["pushState"];
        history.replaceState = originalReplace as History["replaceState"];
      }
      for (const t of timeouts) clearTimeout(t);
      timeouts.clear();
    },
  };
}
