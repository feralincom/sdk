# Feralin Python SDK (`feralin`) — UTP v1 server client

Feralin toplayıcısına (`services/collect`, `POST /v1/batch`) **sunucu tarafından** olay gönderen resmî Python SDK'sı
(Django, FastAPI, Flask, worker'lar). Yalnız standart kütüphane (`urllib`, `threading`, `json`, `secrets`); dış
bağımlılık yok. Python ≥ 3.10, tür ipuçları ve `py.typed` ile.

## Durum (dürüst)

| Konu | Durum |
|---|---|
| Kod: `Client`, `track`, `identify`, `set_consent`, `flush`, `close`, `status` | `TESTING` — gerçek yerel `http.server` ile 28 `unittest` testi geçti |
| Yayın: `pip install feralin` | **Yayında (19 Kasım 2026): `feralin==0.1.0` PyPI'de.** |
| Gerçek `collect` ile uçtan uca | Bu ortamda yalnız sahte sunucu; live-dev'de `examples/basic.py` ile `202` kanıtı alınmalı |
| İmzalı server event (`verified`), OTel tracing, async istemci | Yok — F3/F5 (`verified` alanı istemciden **asla** gönderilmez; `track_revenue` `feralin_purchase` istemci beyanı üretir, doğrulama sunucuda) |

## Kurulum

Yayın öncesi monorepo içinden:

```bash
pip install -e sdks/python          # veya: PYTHONPATH=sdks/python/src
```

Yayın sonrası (henüz çalışmaz): `pip install feralin`.

## Kullanım

```python
from feralin import Client, Consent, Context, RejectedError, TemporaryError

client = Client(
    "pk_live_…", "https://collect.example.com",
    consent=Consent(analytics=True),  # consent-first: varsayılan analytics=False
    flush_interval=2.0,               # 0 → arka plan (daemon thread) gönderici kapalı
    batch_size=100,                   # ≤ 500
    queue_limit=1000,                 # aşılırsa en eski olay atılır
    timeout=10.0,
)

event = client.track(
    "order_completed",                                   # snake_case, ≤100
    {"order_id": "ord_1", "amount": 249.9},              # ≤100 anahtar, ^[a-zA-Z][a-zA-Z0-9_]{0,63}$
    user_id="user_42",                                   # müşteri uygulamasının kimliği; PII değil
    context=Context(locale="tr-TR", timezone="Europe/Istanbul"),
)
# consent.analytics False → None döner (olay üretilmez, istisna yok; Web SDK ile tutarlı)
# doğrulama hatası       → InvalidEventError (ValueError)

result = client.flush()          # fırlatmaz; sonuç result.error içinde
if result.ok: ...                # 202: result.accepted / rejected / batch_id
elif isinstance(result.error, RejectedError): ...   # 4xx (429 hariç): olaylar atıldı
elif isinstance(result.error, TemporaryError): ...  # 5xx / 429 / ağ: kuyrukta, backoff 1 sn → 30 sn (Retry-After'a uyar)

client.close()                   # kalan olayları en fazla 5 sn içinde gönderir; `with Client(...) as c:` de desteklenir
```

Örnek: `FERALIN_PROJECT_KEY=pk_live_… FERALIN_COLLECT_URL=http://127.0.0.1:8081 PYTHONPATH=sdks/python/src python sdks/python/examples/basic.py`
(yerel `collect` için anahtar `COLLECT_PROJECT_KEYS="pk_live_…=tenant_dev:proj_dev"` ile tanımlanmalı; SDK `pk_` dışındaki anahtarı reddeder).

### Kimlik yöntemleri (UTP §8.2)

```python
client.set_global_properties({"app_release": "2.4.0"})        # adı fr_ ile başlamayan her olaya eklenir; None anahtarı siler
client.set_user_properties({"plan": "pro"}, user_id="user_42")  # fr_user_properties; geçerli özellik yoksa None
client.group("acme-team", {"plan": "team"}, user_id="user_42")  # fr_group; geçersiz group_id → None
client.clear_global_properties()
```

### Hata yakalama (`fr_error`)

```python
client = Client("pk_live_…", "https://collect.example.com", app_version="2.4.0", error_sample_rate=1.0)
try:
    charge()
except Exception as exc:
    client.capture_error(exc, user_id="user_42")  # varsayılan origin "handled"; izin yoksa ya da sınır aşıldıysa None
```

Gövde Android, React Native ve Web SDK ile aynı sözleşmedir: `error_type` (paketsiz tür adı, ≤64), temizlenmiş `message` (URL, e-posta, UUID, rakam içeren uzun belirteç ve en az 7 haneli sayı etiketlenir, ≤200), `fingerprint` (tür ve ilk beş çerçevenin FNV-1a 64 özeti, 16 onaltılı; çerçeve yoksa rakamsız mesaj), `top_frame`, `frame_count`, `app_version` (verildiyse, ≤32), `handled`, `fatal`, `origin` (`handled`, `manual`, `uncaught_exception`). Ham yığın izi, dosya yolu ve satır numarası gitmez. Süreç başına en çok 20, aynı parmak izi için en çok 3 olay; izin yoksa olay üretilmez. Çerçeveler `__traceback__` üzerinden `modül.işlev` biçimindedir, en içteki önce; uygulama çerçevesi varsa standart kütüphane ve SDK çerçeveleri atılır.

Kurallar bütün SDK'larda ve toplayıcıda aynıdır: anahtar `^[a-zA-Z][a-zA-Z0-9_]{0,63}$`, çağrı başına en çok 50 özellik; değer yalnız dizge (≤256 karakter, kontrol karakteri yok, e-posta biçiminde değil), sonlu sayı ya da mantıksal. Doğrulama alanları (`verified`, `receipt` vb.) ve kişisel veriye benzeyen anahtarlar (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) istemcide düşer. Toplayıcı ayrıca projenin özellik izin listesini uygular: listede olmayan anahtar saklanmaz, liste boşsa olay sayılır ama hiçbir özellik saklanmaz. Olayın kendi özelliği aynı anahtardaki globali ezer; global en çok 50 anahtar tutar. `group_id` 1-128 karakterdir, `@` ve kontrol karakteri içeremez.

## Sözleşme

- Tel biçimi `packages/schemas/utp/v1/event.schema.json` ile birebir: `platform="python"`, `schema_version=1`,
  `sdk={name:"feralin-python",version:"0.1.0"}`, `occurred_at` UTC RFC3339 ms, `event_id` monotonik ULID.
- `tenant_id`, `project_id`, `verified` **gönderilmez**; sunucu `X-Feralin-Project-Key` bağlamından çözer.
- `Idempotency-Key`, Web SDK ile aynıdır: sıralı tüm `event_id` değerlerinin FNV-1a 64 özeti ve olay sayısı. Sonucu bilinmeyen batch aynı içerik ve aynı anahtarla yeniden denenir; araya giren olaylar sonraki batch'e kalır.
- `fr_click` yalnız `consent.advertising` doğruysa gönderilir, aksi halde olaydan çıkarılır.
- Aynı anda tek gönderici; `track` iş parçacığı güvenlidir. Kuyruk bellek içidir (süreç ölürse kaybolur).
- Taşıma katmanı değiştirilebilir: `Client(..., transport=my_transport)` (`feralin.Transport` imzası).
- Loglar `logging.getLogger("feralin")` altında; anahtar ve ham olay içeriği loglanmaz.

## Geliştirme

```bash
python -m unittest discover -s sdks/python/tests -v
python -I -m compileall -q sdks/python
```
