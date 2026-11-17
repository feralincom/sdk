// Çerçeve hata köprülerinin ortak katmanı: React ErrorBoundary, Vue `app.config.errorHandler` ve Angular `ErrorHandler` buradan
// `fr_error` üretir. Bu dosya sdks/web-react, sdks/web-vue ve sdks/web-angular altında birebir aynıdır; Vue ve Angular testi eşitliği
// denetler. Gövde, PII temizliği, parmak izi, örnekleme ve hata fırtınası sınırı `@feralin/web/errors` modülündendir (npm'deki
// @feralin/web@0.1.0 bu alt yolu taşır); izin kapısı çekirdek istemcidedir. Pencere dinleyicisi kurulmaz: çerçevenin yakaladığı hata
// pencereye ulaşmaz, pencere hataları için `@feralin/web/errors` ayrıca kurulabilir.
//
// Modül ilk hatada dinamik olarak yüklenir: paketleyici onu ayrı parçaya ayırır (çekirdek bütçesine girmez) ve CommonJS çıktısında
// `require` yalnız hata anında çalışır; ESM alt yolunu `require` edemeyen eski Node sürümünde paket yüklenirken düşmez.
import type { FeralinHandle } from "./handle.js";

type ErrorsModule = typeof import("@feralin/web/errors");
type Reporter = ReturnType<ErrorsModule["captureErrors"]>;

/** Hata bildirimi ayarları; aynı istemci için ilk bildirimde bir kez okunur (sınır sayaçları sayfa yüklemesi boyunca paylaşılır). */
export interface FeralinErrorOptions {
  /** Uygulama sürümü (≤32); sürüm kırılımı ve kaynak haritası eşlemesi için. */
  appVersion?: string;
  /** Sembolleştirme için çerçeve konumları (`frames`: dosya taban adı, satır, sütun) gönderilsin mi; varsayılan true. */
  sourcePositions?: boolean;
  /** Örnekleme oranı 0..1; varsayılan 1. */
  sampleRate?: number;
  /** Sayfa yüklemesi başına en çok hata olayı; varsayılan 20. */
  maxEvents?: number;
  /** Aynı parmak izi için sayfa yüklemesi başına en çok olay; varsayılan 3. */
  maxPerFingerprint?: number;
}

// Dinleyici kurmayan pencere: `captureErrors` yalnız elle bildirim (`capture`) için kullanılır.
const NO_WINDOW: Pick<Window, "addEventListener" | "removeEventListener"> = { addEventListener() {}, removeEventListener() {} };
const reporters = new WeakMap<FeralinHandle, Reporter>();
// Aynı hata nesnesi (ör. React geliştirme kipinde çift çağrı, iç içe sınırlar) bir kez bildirilir.
const reported = new WeakSet<object>();
let loading: Promise<ErrorsModule> | undefined;

/**
 * V8 yığın izinin `Tür: mesaj` başlığını çıkarır. npm'deki @feralin/web@0.1.0 mesajında `@` olan başlığı (ör. e-posta) Firefox çerçevesi
 * sanıp `top_frame` alanına yazar; köprü bu yüzden başlıksız kopya verir. Tür adı ve mesaj aynen kalır (mesajı çekirdek temizler).
 */
function withoutStackHeader(error: unknown): unknown {
  if (error === null || typeof error !== "object") return error;
  const e = error as { name?: unknown; message?: unknown; stack?: unknown; constructor?: { name?: unknown } };
  if (typeof e.stack !== "string") return error;
  const lines = e.stack.split("\n");
  const first = lines.findIndex((line) => line.trim().startsWith("at "));
  if (first <= 0) return error;
  const name = typeof e.name === "string" && e.name ? e.name : typeof e.constructor?.name === "string" && e.constructor.name ? e.constructor.name : "Error";
  return { name, message: typeof e.message === "string" ? e.message : "", stack: lines.slice(first).join("\n") };
}

/**
 * Çerçevenin yakaladığı hatayı `fr_error` olarak bildirir: `origin: "uncaught_exception"`, `handled: false`, `fatal: false`. Sunucuda
 * (boş tutamak), izin yokken, örneklemeye ya da sınıra takılınca ve aynı hata nesnesi ikinci kez geldiğinde false ile çözülür. İzin
 * hata anında denetlenir; izin yokken sınır sayacı harcanmaz. Fırlatmaz ve reddedilmez.
 */
export function reportFrameworkError(feralin: FeralinHandle, error: unknown, options?: FeralinErrorOptions): Promise<boolean> {
  try {
    if (!feralin.active || feralin.getStatus()?.consent.analytics !== true) return Promise.resolve(false);
    if (error !== null && typeof error === "object") {
      if (reported.has(error)) return Promise.resolve(false);
      reported.add(error);
    }
    loading ??= import("@feralin/web/errors");
  } catch {
    return Promise.resolve(false);
  }
  return loading
    .then((errors) => {
      let reporter = reporters.get(feralin);
      if (!reporter) {
        reporter = errors.captureErrors({ ...options, client: feralin, window: NO_WINDOW });
        reporters.set(feralin, reporter);
      }
      // `capture` kökeni olduğu gibi gövdeye yazar; tip yalnız elle bildirim kökenlerini listeler (@feralin/web@0.1.0).
      return reporter.capture(withoutStackHeader(error), { origin: "uncaught_exception" as "handled" });
    })
    .catch(() => {
      // Yükleme başarısızsa sonraki hata yeniden dener.
      loading = undefined;
      return false;
    });
}
