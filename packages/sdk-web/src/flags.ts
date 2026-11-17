// Feralin Web SDK — özellik bayrağı istemcisi (F4-E02-T03, ayrı giriş noktası). `POST /v1/flags/evaluate` ucunu herkese açık proje
// anahtarıyla çağırır; özne çekirdek SDK'nın kimliğidir (varsa user_id, yoksa anonymous_id), tarayıcı özelliği karıştırılmaz.
// Sunucu atamayı belirlenimci özetle hesaplar; istemci yalnız sonucu okur ve ilk okumada bir kez maruz kalma olayı gönderir.
// Sonuç bellek içinde kısa süre tutulur; depoya yazılmaz.
import type { Consent } from "./types";

export interface FlagsClient {
  track(eventName: string, properties?: Record<string, unknown>): unknown;
  getStatus(): { consent: Consent; anonymous_id: string; user_id: string | null } | null;
}

export interface FlagsOptions {
  client: FlagsClient;
  /** saas-api kökü, ör. https://feralin.com/api */
  apiUrl: string;
  /** Herkese açık proje anahtarı (pk_…). */
  projectKey: string;
  /** İstenen anahtarlar; verilmezse projenin bütün bayrakları değerlendirilir. */
  keys?: string[];
  /** Sonucun bellek içinde geçerlilik süresi; varsayılan 60 sn. */
  ttlMs?: number;
  fetch?: typeof fetch;
}

export interface FlagResult {
  key: string;
  enabled: boolean;
  variant: string | null;
  reason: string;
}

export interface EvaluateResponse {
  flags: FlagResult[];
  unknown_keys: string[];
  evaluated_at: string;
}

export const FLAG_EXPOSURE_EVENT = "fr_flag_exposure";
const DEFAULT_TTL_MS = 60_000;
const KEY_PATTERN = /^[a-z][a-z0-9_-]{0,63}$/;
/** Sunucu özne kuralıyla aynı (flag-schemas.ts): e-posta ve kısa sıra numarası özne olamaz. */
const SUBJECT_PATTERN = /^[A-Za-z0-9_:-]{8,128}$/;
/** 429 ve 5xx sonrası bekleme: Retry-After alt sınırdır, yoksa 30 sn; üst sınır 5 dk. Bekleme boyunca eski sonuç ya da varsayılanlar sürer. */
const MIN_BACKOFF_MS = 30_000;
const MAX_BACKOFF_MS = 5 * 60_000;

export class FeralinFlags {
  private readonly opts: Required<Pick<FlagsOptions, "ttlMs">> & FlagsOptions;
  private readonly fetchImpl: typeof fetch;
  private results = new Map<string, FlagResult>();
  private loadedAt = 0;
  private loadedFor = "";
  private readonly exposed = new Set<string>();
  private pending: Promise<void> | null = null;
  /** Bu andan önce sunucuya yeniden sorulmaz (429 ya da 5xx sonrası). */
  private notBefore = 0;

  constructor(options: FlagsOptions) {
    if (!options?.client || !options?.apiUrl || !options?.projectKey) throw new Error("feralin flags: client, apiUrl ve projectKey zorunlu");
    if (!/^pk_/.test(options.projectKey.trim())) throw new Error("feralin flags: projectKey pk_ ile başlamalı");
    this.opts = { ttlMs: DEFAULT_TTL_MS, ...options, projectKey: options.projectKey.trim() };
    this.fetchImpl = options.fetch ?? (typeof fetch !== "undefined" ? fetch.bind(globalThis) : (() => { throw new Error("feralin flags: fetch yok"); }));
  }

  /**
   * Özne: analitik izni varsa kullanıcı kimliği (yoksa anonim kimlik); izin yokken yalnız bellekteki anonim kimlik gider, müşterinin
   * `identify` ile verdiği kimlik izinsiz hiçbir isteğe binmez. Sunucu özneyi saklamaz; yalnız belirlenimci özet ve kitle üyeliği için okur.
   */
  private subject(): string | null {
    const status = this.opts.client.getStatus();
    if (!status) return null;
    const candidate = status.consent.analytics ? (status.user_id ?? status.anonymous_id) : status.anonymous_id;
    // Sunucu kuralı: en az 8 karakter, `@` ve `.` yok. Uymayan kullanıcı kimliğinde anonim kimliğe düşülür.
    if (candidate && SUBJECT_PATTERN.test(candidate)) return candidate;
    return status.anonymous_id && SUBJECT_PATTERN.test(status.anonymous_id) ? status.anonymous_id : null;
  }

  /** Sonuçları yükler ya da yeniler; eşzamanlı çağrılar tek isteğe iner. Ağ hatasında eski sonuç kalır, hata fırlatılmaz. */
  load(force = false): Promise<void> {
    const subject = this.subject();
    const fresh = subject !== null && subject === this.loadedFor && Date.now() - this.loadedAt < this.opts.ttlMs;
    if (!force && fresh) return Promise.resolve();
    // Sınır ya da sunucu hatasından sonra bekleme: zorlanan yükleme de beklemeyi aşmaz (herkese açık anahtar sunucuyu döverek açmaz).
    if (Date.now() < this.notBefore) return Promise.resolve();
    if (this.pending) return this.pending;
    this.pending = this.request(subject).finally(() => {
      this.pending = null;
    });
    return this.pending;
  }

  private async request(subject: string | null): Promise<void> {
    if (subject === null) return;
    const keys = this.opts.keys?.filter((key) => KEY_PATTERN.test(key));
    try {
      const res = await this.fetchImpl(`${this.opts.apiUrl.replace(/\/$/, "")}/v1/flags/evaluate`, {
        method: "POST",
        headers: { "content-type": "application/json", authorization: `Bearer ${this.opts.projectKey}` },
        body: JSON.stringify({ subject, ...(keys && keys.length > 0 ? { keys } : {}) }),
      });
      if (res.status === 429 || res.status >= 500) {
        const header = Number(res.headers?.get?.("retry-after") ?? "");
        const floor = Number.isFinite(header) && header > 0 ? header * 1000 : 0;
        this.notBefore = Date.now() + Math.min(MAX_BACKOFF_MS, Math.max(MIN_BACKOFF_MS, floor));
        return;
      }
      if (res.status !== 200) return;
      const data = (await res.json()) as EvaluateResponse;
      const next = new Map<string, FlagResult>();
      for (const flag of data.flags ?? []) {
        if (typeof flag?.key === "string") next.set(flag.key, { key: flag.key, enabled: flag.enabled === true, variant: typeof flag.variant === "string" ? flag.variant : null, reason: String(flag.reason ?? "") });
      }
      // Özne değiştiyse (giriş/çıkış) maruz kalma kaydı sıfırlanır: yeni özne için yeni kayıt.
      if (subject !== this.loadedFor) this.exposed.clear();
      this.results = next;
      this.loadedAt = Date.now();
      this.loadedFor = subject;
    } catch {
      // Ağ hatası: eski sonuç ya da varsayılanlar sürer.
    }
  }

  /** Bayrak açık mı; yüklenmemiş ya da bilinmeyen anahtarda `fallback`. İlk okumada maruz kalma olayı gider (analitik izni varsa). */
  isEnabled(key: string, fallback = false): boolean {
    const result = this.results.get(key);
    if (!result) return fallback;
    this.expose(result);
    return result.enabled;
  }

  /** Varyant anahtarı; kapalı bayrakta ya da varyantsız bayrakta `fallback`. */
  variant(key: string, fallback: string | null = null): string | null {
    const result = this.results.get(key);
    if (!result || !result.enabled) return fallback;
    this.expose(result);
    return result.variant ?? fallback;
  }

  /** Yüklenmiş sonuçların kopyası (hata ayıklama). */
  snapshot(): FlagResult[] {
    return [...this.results.values()].map((result) => ({ ...result }));
  }

  private expose(result: FlagResult): void {
    if (this.exposed.has(result.key)) return;
    this.exposed.add(result.key);
    // Çekirdek analitik izni yoksa track null döner ve olay üretilmez; bu doğru davranıştır.
    this.opts.client.track(FLAG_EXPOSURE_EVENT, { flag_key: result.key, variant: result.variant ?? "", enabled: result.enabled });
  }
}
