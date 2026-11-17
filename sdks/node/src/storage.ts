// Feralin Node.js SDK — isteğe bağlı kalıcı kuyruk (`storageDirectory`). Bellek içi kuyruk çalışan kopyadır; bu dosya onu diske
// yansıtır ki süreç çökerse olaylar sonraki açılışta (ya da aynı dizini kullanan başka bir süreçte) gönderilsin.
//
// Her istemci örneği kendi günlüğüne yazar (`fq-<konak özeti>-<pid>-<rastgele>.jsonl`): eşzamanlı süreçler aynı dosyaya yazmaz, kilit
// gerekmez. Günlük ekleme sıralı satırlardır: `e <ms> <olay JSON>` kuyruğa giren olay, `p <kimlikler>` gönderime sabitlenen batch,
// `a <kimlikler>` kuyruktan çıkan olaylar (kabul, kalıcı ret, sınır). Sabitlenen batch'in bileşimi de yazıldığı için çöküşten sonra
// aynı olaylar aynı sırayla, yani aynı Idempotency-Key ile gönderilir; sunucu yanıtı yolda kaybolduysa ikinci outbox satırı yazılmaz.
//
// Sahipsiz günlük: sahibi aynı konakta ölmüş süreçse hemen, aksi hâlde son yazımı (kalp atışı) `staleMs` kadar eskiyse devralınır.
// Devralma atomik `rename` ile olur; iki süreç aynı günlüğü alamaz. Devralan olayları önce kendi günlüğüne yazar, sonra eskisini siler.
// Yazım `fsync` yapmaz: süreç çökmesinde olaylar işletim sistemi önbelleğinden diske iner, güç kesintisinde son satırlar kaybolabilir.
import { createHash, randomBytes } from "node:crypto";
import { closeSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, statSync, unlinkSync, utimesSync, writeSync } from "node:fs";
import { hostname } from "node:os";
import { join, resolve } from "node:path";

/** Kuyruktaki olay: serileştirilmiş gövde, bayt boyu ve kuyruğa giriş zamanı (ms). */
export interface StoredEvent {
  id: string;
  json: string;
  bytes: number;
  name: string;
  at: number;
}

export interface QueueSnapshot {
  /** Bileşimi sabitlenmiş batch'ler (gönderimde olan ve devralınanlar). */
  batches: readonly (readonly StoredEvent[])[];
  events: readonly StoredEvent[];
}

export interface FileQueueOptions {
  directory: string;
  /** Devralınan olay bundan eskiyse (ms) gönderilmez. */
  maxAgeMs: number;
  /** Günlük sıkıştırılırken yazılacak canlı durum. */
  snapshot: () => QueueSnapshot;
  /** Olay yaşı için saat (istemcinin `now` seçeneği). Dosya zamanları her zaman gerçek saatle karşılaştırılır. */
  now?: () => number;
  /** Kalp atışı bu kadar eskiyen günlük sahipsiz sayılır. */
  staleMs?: number;
  /** Test için süreç canlılık denetimi. */
  isAlive?: (pid: number) => boolean;
}

export interface RecoveredQueue {
  batches: StoredEvent[][];
  events: StoredEvent[];
  /** Yaş sınırını aştığı için atılan olay sayısı. */
  expired: number;
  /** Devralınan günlük sayısı. */
  files: number;
}

export const DEFAULT_STALE_MS = 120_000;
const JOURNAL_NAME = /^fq-([0-9a-f]{8})-(\d{1,10})-([0-9a-z]{1,40})\.jsonl$/;
const TEMP_SUFFIX = ".tmp";
// Günlük bu boyu geçmeden ve canlı olayların iki katına ulaşmadan yeniden yazılmaz.
const COMPACT_MIN_BYTES = 256 * 1024;
const MAX_IDS_PER_LINE = 500;
// Bu süreçte açık olan günlükler: aynı süreçteki ikinci istemci örneği, aynı pid'i taşıyan canlı günlüğü sahipsiz sanmasın.
const openJournals = new Set<string>();

function processAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (err) {
    // EPERM: süreç var ama sinyal gönderilemiyor. ESRCH ve ötekiler: süreç yok.
    return (err as NodeJS.ErrnoException).code === "EPERM";
  }
}

/** Günlük adındaki konak alanı: konak adının kısa özeti (ad dosya sistemine yazılmaz). */
export function storageHostId(name: string = hostname()): string {
  return createHash("sha256").update(name).digest("hex").slice(0, 8);
}

function eventLine(item: StoredEvent): string {
  return `e ${item.at} ${item.json}\n`;
}

function idLines(kind: "p" | "a", ids: readonly string[]): string {
  let out = "";
  for (let i = 0; i < ids.length; i += MAX_IDS_PER_LINE) out += `${kind} ${ids.slice(i, i + MAX_IDS_PER_LINE).join(",")}\n`;
  return out;
}

/**
 * Günlük metnini canlı duruma çevirir. Yarım kalmış son satır (çöküş anındaki yazım) ve bozuk satır atlanır. Bileşimi tam olarak canlı
 * olan `p` kayıtları batch olarak, kalan canlı olaylar sırasıyla döner.
 */
export function parseJournal(text: string): { batches: StoredEvent[][]; events: StoredEvent[] } {
  const live = new Map<string, StoredEvent>();
  const pins: string[][] = [];
  const end = text.lastIndexOf("\n");
  if (end >= 0) {
    for (const line of text.slice(0, end).split("\n")) {
      const kind = line[0];
      const rest = line.slice(2);
      if (line[1] !== " " || rest === "") continue;
      if (kind === "e") {
        const space = rest.indexOf(" ");
        const at = Number(rest.slice(0, space));
        const json = rest.slice(space + 1);
        if (space <= 0 || !Number.isFinite(at)) continue;
        try {
          const event = JSON.parse(json) as { event_id?: unknown; event_name?: unknown };
          if (typeof event.event_id !== "string" || !event.event_id || typeof event.event_name !== "string") continue;
          live.set(event.event_id, { id: event.event_id, json, bytes: Buffer.byteLength(json), name: event.event_name, at });
        } catch {
          // Bozuk satır: olay atlanır, günlüğün kalanı okunur.
        }
      } else if (kind === "p") {
        pins.push(rest.split(","));
      } else if (kind === "a") {
        for (const id of rest.split(",")) live.delete(id);
      }
    }
  }
  const batches: StoredEvent[][] = [];
  const batched = new Set<string>();
  // Uzun batch birkaç `p` satırına bölünür; ardışık satırlar aynı batch'tir ve ilk olay yalnız bir batch'e girer.
  let current: StoredEvent[] = [];
  let broken = false;
  const close = (): void => {
    if (current.length && !broken) {
      batches.push(current);
      for (const item of current) batched.add(item.id);
    }
    current = [];
    broken = false;
  };
  for (const ids of pins) {
    for (const id of ids) {
      const item = live.get(id);
      if (!item || batched.has(id) || current.includes(item)) broken = true;
      else current.push(item);
    }
    if (ids.length < MAX_IDS_PER_LINE) close();
  }
  close();
  return { batches, events: [...live.values()].filter((item) => !batched.has(item.id)) };
}

export class FileQueue {
  readonly path: string;
  private readonly directory: string;
  private readonly host: string;
  private readonly owner: string;
  private readonly maxAgeMs: number;
  private readonly staleMs: number;
  private readonly snapshot: () => QueueSnapshot;
  private readonly now: () => number;
  private readonly isAlive: (pid: number) => boolean;
  private readonly live = new Map<string, number>();
  private fd: number | null;
  private claims = 0;
  private journalBytes = 0;
  private compactAfter = COMPACT_MIN_BYTES;
  /** Canlı olayların toplam gövde baytı (boyut sınırı bununla denetlenir). */
  liveBytes = 0;

  /** Dizin yoksa oluşturur ve bu örneğin günlüğünü açar; yazılamıyorsa fırlatır (yapılandırma hatası). */
  constructor(options: FileQueueOptions) {
    this.directory = resolve(options.directory);
    this.maxAgeMs = options.maxAgeMs;
    this.staleMs = options.staleMs ?? DEFAULT_STALE_MS;
    this.snapshot = options.snapshot;
    this.now = options.now ?? Date.now;
    this.isAlive = options.isAlive ?? processAlive;
    this.host = storageHostId();
    this.owner = `fq-${this.host}-${process.pid}-${Date.now().toString(36)}${randomBytes(4).toString("hex")}`;
    this.path = join(this.directory, `${this.owner}.jsonl`);
    // Olaylar diskte düz JSON durur: dizin ve dosya yalnız süreç kullanıcısına açılır (POSIX; Windows'ta ACL devralınır).
    mkdirSync(this.directory, { recursive: true, mode: 0o700 });
    this.fd = openSync(this.path, "wx", 0o600);
    openJournals.add(this.path);
  }

  get open(): boolean {
    return this.fd !== null;
  }

  get size(): number {
    return this.live.size;
  }

  has(id: string): boolean {
    return this.live.has(id);
  }

  private write(text: string): void {
    if (this.fd === null || text === "") return;
    this.journalBytes += writeSync(this.fd, text);
  }

  /** Kuyruğa giren olayı günlüğe yazar. */
  append(item: StoredEvent): void {
    if (this.fd === null) return;
    this.write(eventLine(item));
    this.live.set(item.id, item.bytes);
    this.liveBytes += item.bytes;
  }

  /** Gönderime sabitlenen batch'in bileşimini yazar: çöküşten sonra aynı Idempotency-Key ile gönderilebilsin. */
  pin(batch: readonly StoredEvent[]): void {
    this.write(idLines("p", batch.map((item) => item.id)));
  }

  /** Kuyruktan çıkan olayları (kabul, kalıcı ret, sınır aşımı) yazar; kuyruk boşaldıysa günlük sıfırlanır. */
  remove(items: readonly StoredEvent[]): void {
    if (this.fd === null || items.length === 0) return;
    const ids: string[] = [];
    for (const item of items) {
      const bytes = this.live.get(item.id);
      if (bytes === undefined) continue;
      this.live.delete(item.id);
      this.liveBytes -= bytes;
      ids.push(item.id);
    }
    if (ids.length === 0) return;
    if (this.live.size === 0) {
      this.truncate();
      return;
    }
    this.write(idLines("a", ids));
    if (this.journalBytes > this.compactAfter && this.journalBytes > 2 * this.liveBytes) this.rewrite();
  }

  /** Bütün olayları siler (izin geri çekildi, `reset`). */
  clear(): void {
    this.live.clear();
    this.liveBytes = 0;
    this.truncate();
  }

  private truncate(): void {
    if (this.fd === null || this.journalBytes === 0) return;
    // Ekleme kipindeki tanıtıcıyı kısaltmak Windows'ta reddedilir; dosya yeniden açılarak sıfırlanır.
    closeSync(this.fd);
    this.fd = null;
    this.fd = openSync(this.path, "w", 0o600);
    this.journalBytes = 0;
    this.compactAfter = COMPACT_MIN_BYTES;
  }

  /** Günlüğü canlı durumla yeniden yazar: geçici dosyaya yazıp atomik olarak yerine koyar. */
  private rewrite(): void {
    if (this.fd === null) return;
    const state = this.snapshot();
    let text = "";
    for (const batch of state.batches) {
      for (const item of batch) text += eventLine(item);
      text += idLines("p", batch.map((item) => item.id));
    }
    for (const item of state.events) text += eventLine(item);
    const temp = `${this.path}${TEMP_SUFFIX}`;
    const tempFd = openSync(temp, "w", 0o600);
    let written: number;
    try {
      written = writeSync(tempFd, text);
    } finally {
      closeSync(tempFd);
    }
    closeSync(this.fd);
    this.fd = null;
    try {
      renameSync(temp, this.path);
      this.journalBytes = written;
      this.compactAfter = COMPACT_MIN_BYTES;
    } catch {
      // Yerine koyma reddedildiyse (ör. Windows'ta dosya taranıyor) eski günlük geçerlidir; boyu iki katına çıkınca yeniden denenir.
      this.compactAfter = this.journalBytes * 2;
      try {
        unlinkSync(temp);
      } catch {
        // Geçici dosya sonraki taramada silinir.
      }
    }
    this.fd = openSync(this.path, "a", 0o600);
  }

  /**
   * Günlüğün son yazım zamanını tazeler: boşta bekleyen canlı süreç sahipsiz sayılmasın. Günlük başka bir süreççe devralınmışsa
   * (bu süreç `staleMs` boyunca hiç çalışamadıysa) canlı durumla yeniden oluşturulur.
   */
  heartbeat(): void {
    if (this.fd === null) return;
    const at = new Date();
    try {
      utimesSync(this.path, at, at);
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== "ENOENT") throw err;
      closeSync(this.fd);
      this.fd = null;
      this.fd = openSync(this.path, "wx", 0o600);
      this.journalBytes = 0;
      this.rewrite();
    }
  }

  /**
   * Dizindeki sahipsiz günlükleri devralır. Olaylar bu örneğin günlüğüne yazılır, sonra eski dosya silinir; arada çöküş olursa olay
   * iki günlükte de kalır ve sonraki devralmada kimliğe göre teke iner. Yaş sınırını aşan olay atılır.
   */
  recover(): RecoveredQueue {
    const out: RecoveredQueue = { batches: [], events: [], expired: 0, files: 0 };
    if (this.fd === null) return out;
    const realNow = Date.now();
    const ownName = `${this.owner}.jsonl`;
    for (const name of readdirSync(this.directory)) {
      const full = join(this.directory, name);
      if (name.endsWith(TEMP_SUFFIX)) {
        // Yarım kalmış sıkıştırmanın artığı: asıl günlük yerinde durduğu için içerik gerekmez.
        if (name !== `${ownName}${TEMP_SUFFIX}` && this.ageOf(full, realNow) >= this.staleMs) this.tryUnlink(full);
        continue;
      }
      const match = JOURNAL_NAME.exec(name);
      if (!match || name === ownName) continue;
      const pid = Number(match[2]);
      // Aynı konakta pid ile karar verilir. Pid bu sürecinki ise günlük ya bu süreçteki başka bir istemcinindir (açık) ya da aynı pid'i
      // almış önceki bir sürecindir (kapsayıcıda yeniden başlama): o hâlde sahibi ölüdür.
      const dead = match[1] === this.host && (pid === process.pid ? !openJournals.has(full) : !this.isAlive(pid));
      if (!dead && this.ageOf(full, realNow) < this.staleMs) continue;
      const claimed = join(this.directory, `${this.owner}r${++this.claims}.jsonl`);
      let text: string;
      try {
        // Önce tazele, sonra al: yeni ad bu sürecin kimliğini ve taze zamanı taşır, başka süreç onu sahipsiz görmez.
        const at = new Date();
        utimesSync(full, at, at);
        renameSync(full, claimed);
        text = readFileSync(claimed, "utf8");
      } catch {
        // Başka bir süreç daha önce aldı ya da dosya okunamıyor: atlanır, sonraki taramada yeniden bakılır.
        continue;
      }
      out.files++;
      const parsed = parseJournal(text);
      const keep = (item: StoredEvent): boolean => {
        if (this.live.has(item.id)) return false;
        if (this.now() - item.at > this.maxAgeMs) {
          out.expired++;
          return false;
        }
        return true;
      };
      for (const batch of parsed.batches) {
        const kept = batch.filter(keep);
        for (const item of kept) this.append(item);
        // Bileşimi bozulan batch (eskiyen ya da zaten bilinen olay) sabit anahtarını yitirir; kalanlar sıradan olay olur.
        if (kept.length === batch.length) {
          this.pin(kept);
          out.batches.push(kept);
        } else out.events.push(...kept);
      }
      for (const item of parsed.events) {
        if (!keep(item)) continue;
        this.append(item);
        out.events.push(item);
      }
      this.tryUnlink(claimed);
    }
    return out;
  }

  private ageOf(path: string, realNow: number): number {
    try {
      return realNow - statSync(path).mtimeMs;
    } catch {
      return -1;
    }
  }

  private tryUnlink(path: string): void {
    try {
      unlinkSync(path);
    } catch {
      // Silinemeyen dosya sonraki taramada yeniden denenir.
    }
  }

  /** Günlüğü kapatır. Kuyruk boşsa dosya silinir; değilse yerinde kalır ve sonraki açılışta devralınır. */
  close(): void {
    if (this.fd === null) return;
    closeSync(this.fd);
    this.fd = null;
    openJournals.delete(this.path);
    if (this.live.size === 0) this.tryUnlink(this.path);
  }
}
