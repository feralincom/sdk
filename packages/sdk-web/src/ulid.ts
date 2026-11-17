// ULID (Crockford base32, 26 karakter): zaman sıralı, çakışmasız event_id. Monotonik artış aynı ms içinde korunur.
const ENC = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
let lastTime = 0;
let lastRand: number[] = [];

function randomBytes(n: number): number[] {
  const out = new Array<number>(n);
  const c = typeof crypto !== "undefined" ? crypto : undefined;
  if (c?.getRandomValues) {
    const buf = new Uint8Array(n);
    c.getRandomValues(buf);
    for (let i = 0; i < n; i++) out[i] = buf[i]! & 31;
  } else {
    for (let i = 0; i < n; i++) out[i] = Math.floor(Math.random() * 32);
  }
  return out;
}

export function ulid(now: number = Date.now()): string {
  let time = "";
  let t = now;
  for (let i = 0; i < 10; i++) { time = ENC[t % 32] + time; t = Math.floor(t / 32); }
  let rand: number[];
  if (now === lastTime) {
    rand = lastRand.slice();
    // Aynı milisaniyede monotonik artış
    for (let i = rand.length - 1; i >= 0; i--) { if (rand[i]! < 31) { rand[i]!++; break; } rand[i] = 0; }
  } else {
    rand = randomBytes(16);
  }
  lastTime = now; lastRand = rand;
  return time + rand.map((v) => ENC[v]).join("");
}
