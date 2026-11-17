# feralin-django

`feralin` üstünde Django ara katmanı. Her isteğe `request.feralin` ekler; izin ve kimlik o isteğin kullanıcısından alınır. WSGI ve ASGI altında çalışır.

## Durum

| Konu | Durum |
|---|---|
| Birim testleri (Django 6.1, gerçek ara katman zinciri, sync ve async) | Geçiyor |
| Temiz kurulum + gerçek `services/collect` | `scripts/sdk-e2e/run.mjs python-django` ile geçti; istekler Django test istemcisinden girer |
| Django 4.2-5.x, gerçek WSGI/ASGI sunucusu | Sınanmadı |
| PyPI yayını | `BLOCKED_EXTERNAL`: hesap yok, `feralin` çekirdeği de yayınlanmadı |

## Kurulum

```bash
pip install ./sdks/python ./sdks/python-django
```

## Kullanım

```python
# settings.py
MIDDLEWARE = [..., "feralin_django.FeralinMiddleware"]
FERALIN = {
    "PROJECT_KEY": os.environ["FERALIN_PROJECT_KEY"],  # yalnız pk_ anahtarı
    "COLLECT_URL": "https://collect.example.com",
    "CONSENT_RESOLVER": "uygulama.feralin.izin",
}

# uygulama/feralin.py
from feralin import Consent

def izin(request):
    return Consent(analytics=request.COOKIES.get("izin") == "evet")

# views.py
def siparis(request):
    request.feralin.track("order_completed", {"order_id": "ord_1"})
    return HttpResponse(status=201)
```

İstek dışı kodda (Celery, yönetim komutu): `get_pool().track(Consent(analytics=True), "job_done")`.

## İzin

Çekirdek izni istemci düzeyinde tutar. Sunucuda her istek farklı kullanıcıya ait olduğundan bu paket izin değeri başına ayrı istemci kullanır (en çok 8 arka plan iş parçacığı). `CONSENT_RESOLVER` yoksa, hata atarsa veya `Consent` döndürmezse izin yok sayılır, istek düşmez. Çözümleyici eşzamanlıdır; ASGI altında veritabanına gidecekse sonucu önceden hazırlayın. `fr_click` yalnız `advertising=True` iken gider.

## Veri

IP, User-Agent ve çerez okunmaz. `page_url` sorgusuz, `referrer` yalnız origin, `locale` ilk dil etiketidir. Yolda kişisel veri varsa `"INCLUDE_CONTEXT": False` verin. Geçersiz olay istisna atmaz: `None` döner, uyarı loglanır.

## Desteklenmeyenler

`utm_*` sunucu tarafında okunmaz. `request.user` otomatik okunmaz, `USER_ID_RESOLVER` verilmelidir. `group`, `set_user_properties`, `track_revenue`, hata raporlama, OTel ve kalıcı kuyruk yoktur. Kuyruk süreç belleğindedir: süreç öldürülürse gönderilmemiş olay kaybolur, normal çıkışta `atexit` ile gönderim denenir.

## Test

```bash
python -m venv .venv
.venv/Scripts/python -m pip install django ./sdks/python
cd sdks/python-django && ../../.venv/Scripts/python -X utf8 -m unittest discover -s tests
```
