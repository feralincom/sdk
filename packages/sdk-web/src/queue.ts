// Çevrimdışı/toplu gönderim kuyruğu. localStorage varsa kalıcı; yoksa bellek içi. Kuyruk sınırı aşılınca en eski atılır.
import type { UtpEvent } from "./types";

export interface QueueStorage {
  get(key: string): string | null;
  set(key: string, value: string): void;
  remove(key: string): void;
}

export class MemoryStorage implements QueueStorage {
  private m = new Map<string, string>();
  get(k: string) { return this.m.get(k) ?? null; }
  set(k: string, v: string) { this.m.set(k, v); }
  remove(k: string) { this.m.delete(k); }
}

export function defaultStorage(): QueueStorage {
  try {
    if (typeof localStorage !== "undefined") {
      const probe = "__fr_probe__";
      localStorage.setItem(probe, "1"); localStorage.removeItem(probe);
      return { get: (k) => localStorage.getItem(k), set: (k, v) => localStorage.setItem(k, v), remove: (k) => localStorage.removeItem(k) };
    }
  } catch { /* özel mod / engelli depolama */ }
  return new MemoryStorage();
}

/**
 * Depo kuyruğun tek gerçek kaynağıdır: her işlem (push, ack, clear, peek, size) önce depoyu okur, sonra değiştirir ve yazar.
 * Aynı origin'deki birden çok sekme aynı anahtarı paylaşır; bellekteki kopya "son yazan kazanır" diye diğer sekmenin gönderilmemiş
 * olaylarını silmez, bir sekmenin onayladığı (ack) olayı da başka sekme yeniden göndermez. Depo okunamıyorsa (özel mod) bellekteki son
 * kopyayla çalışır. Okuma-değiştirme-yazma tek eşzamanlı blokta yapılır; sekmeler arası yarış penceresi bir localStorage çağrısı kadardır.
 */
export class EventQueue {
  /** Son bilinen kopya: yalnız depo okunamadığında kullanılır. */
  private items: UtpEvent[] = [];
  constructor(private storage: QueueStorage, private key: string, private max = 1000) {
    this.items = this.read();
  }
  get size() { return this.read().length; }
  push(e: UtpEvent) {
    const items = this.read();
    if (!items.some((x) => x.event_id === e.event_id)) items.push(e);
    if (items.length > this.max) items.splice(0, items.length - this.max);
    this.write(items);
  }
  /** Gönderim için ilk n öğeyi alır; başarı onayı gelene kadar kuyruktan silinmez (at-least-once). */
  peek(n: number): UtpEvent[] { return this.read().slice(0, n); }
  ack(ids: string[]) {
    const set = new Set(ids);
    this.write(this.read().filter((e) => !set.has(e.event_id)));
  }
  clear() { this.write([]); }
  private read(): UtpEvent[] {
    try {
      const raw = this.storage.get(this.key);
      const parsed = raw ? (JSON.parse(raw) as unknown) : [];
      this.items = Array.isArray(parsed) ? (parsed as UtpEvent[]) : [];
    } catch {
      // Depo okunamadı ya da bozuk: bellekteki son kopya geçerlidir (bozuk kayıt bir sonraki yazımda üzerine yazılır).
    }
    return [...this.items];
  }
  /** Boş kuyruk depoda iz bırakmaz; izin verilmemiş ziyaretçide de hiçbir anahtar yazılmamış olur. */
  private write(items: UtpEvent[]) {
    this.items = items;
    try {
      if (items.length) this.storage.set(this.key, JSON.stringify(items));
      else this.storage.remove(this.key);
    } catch { /* kota */ }
  }
}
