# feralin-fastapi

`feralin` üstünde saf ASGI ara katmanı. FastAPI ve Starlette ile çalışır, yanıt akışına dokunmaz. Her isteğe `request.state.feralin` ekler, uygulama kapanırken kuyruğu gönderir.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (FastAPI 0.162, Starlette 1.10, TestClient) | Geçiyor |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs python-fastapi` ile geçti; istekler TestClient'tan girer |
| Gerçek uvicorn süreci, eski FastAPI sürümleri | Sınanmadı |
| PyPI yayını | Yayında: `pip install feralin-fastapi` (0.1.0, 19 Kasım 2026) |

## Kurulum

```bash
pip install ./sdks/python ./sdks/python-fastapi fastapi
```

## Kullanım

```python
from fastapi import Depends, FastAPI, Request
from feralin import Consent
from feralin_fastapi import FeralinMiddleware, RequestFeralin, get_feralin

def izin(request: Request) -> Consent:
    return Consent(analytics=request.cookies.get("izin") == "evet")

app = FastAPI()
app.add_middleware(
    FeralinMiddleware,
    project_key=os.environ["FERALIN_PROJECT_KEY"],  # yalnız pk_ anahtarı
    collect_url="https://collect.example.com",
    resolve_consent=izin,
)

@app.post("/siparis")
async def siparis(feralin: RequestFeralin = Depends(get_feralin)):
    feralin.track("order_completed", {"order_id": "ord_1"})
```

`track` ağa çıkmaz, async rotada güvenlidir. `flush()` ağı bekler; async rotada `await asyncio.to_thread(feralin.flush)` kullanın.

## İzin

Çekirdek izni istemci düzeyinde tutar; bu paket izin değeri başına ayrı istemci kullanır (en çok 8 arka plan iş parçacığı). Çözümleyici sync veya async olabilir. Yoksa, hata atarsa veya `Consent` döndürmezse izin yok sayılır, istek düşmez. `fr_click` yalnız `advertising=True` iken gider.

## Veri

IP, User-Agent ve çerez okunmaz. `page_url` sorgusuz, `referrer` yalnız origin, `locale` ilk dil etiketidir. Yolda kişisel veri varsa `include_context=False` verin. Geçersiz olay istisna atmaz: `None` döner, uyarı loglanır.

## Desteklenmeyenler

WebSocket bağlantılarına yüzey eklenmez. `utm_*` okunmaz. `group`, `set_user_properties`, `track_revenue`, hata raporlama, OTel ve kalıcı kuyruk yoktur. Lifespan çalışmayan sunucuda kapanış gönderimi `atexit` ile denenir.

## Test

```bash
python -m venv .venv
.venv/Scripts/python -m pip install fastapi httpx ./sdks/python
cd sdks/python-fastapi && ../../.venv/Scripts/python -X utf8 -m unittest discover -s tests
```
