// UTP v1 tipleri — packages/schemas/utp/v1/event.schema.json ile birebir.
export type Consent = { analytics: boolean; advertising?: boolean; personalization?: boolean; session_replay?: boolean };

export type UtpEvent = {
  event_id: string;
  event_name: string;
  occurred_at: string;
  platform: "web";
  schema_version: 1;
  sdk?: { name: string; version: string };
  anonymous_id?: string;
  user_id?: string;
  session_id?: string;
  source?: string;
  properties?: Record<string, unknown>;
  consent: Consent;
  context?: {
    page_url?: string; page_title?: string; referrer?: string; locale?: string; timezone?: string;
    screen?: { width: number; height: number };
  };
};

export type FeralinOptions = {
  /** Proje public anahtarı (pk_live_… / pk_test_…). Gizli anahtar asla tarayıcıya konmaz. */
  projectKey: string;
  /** Collector kökü, ör. https://collect.feralin.com veya https://host:8443/collect */
  collectUrl: string;
  consent?: Consent;
  /** Sayfa görüntülemeyi otomatik gönder (varsayılan true) */
  autoTrack?: boolean;
  /** Toplu gönderim aralığı ms (varsayılan 2000) */
  flushIntervalMs?: number;
  /** Toplu gönderim boyutu (varsayılan 50, en fazla 500) */
  batchSize?: number;
  /** Test/SSR için enjekte edilebilir fetch */
  fetch?: typeof fetch;
  storage?: import("./queue").QueueStorage;
  /** Hata ayıklama günlüğü */
  debug?: boolean;
  /**
   * Kurulum eşleştirme kodu: panelin "Kurulumu doğrula" ekranında üretilen tek kullanımlık kod. İzin verildikten sonra bu örnekte
   * kuyruğa giren ilk olaya `fr_install_code` olarak eklenir; sunucu kodu olay verisinden söker ve kurulumu projeye bağlar.
   * Biçimi geçersizse yok sayılır. Kişisel veri değildir; doğrulama bitince yapılandırmadan kaldırılabilir.
   */
  installCode?: string;
};

/** `rejected_events`: toplayıcı batch içinde tek tek reddettiği olaylar (konum, olay kimliği, neden); batch kabul edilmiştir, reddedilenler yeniden gönderilmez. */
export type RejectedEvent = { index: number; event_id?: string; reason: string };
export type FlushResult = { sent: number; accepted: number; rejected: number; rejected_events?: RejectedEvent[]; batch_id?: string; trace_id?: string; status: number } | { sent: 0; status: 0 };
