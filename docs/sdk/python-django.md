<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Django: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/python-django/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Python |
| Paket | `feralin-django` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | REGISTRY_VERIFIED |
| Kaynak dizin | `sdks/python-django` |
| Registry | PyPI: **PUBLISHED** (sonraki adım: PyPI hesabı ve 2FA; pypi- önekli API anahtarı (twine, TWINE_PASSWORD) ya da pending trusted publisher; feralin çekirdeği önce yayınlanır) |
| Derleme | `python -m build sdks/python-django` |
| Test | `node scripts/sdk-dry-run/python-adapter.mjs sdks/python-django django` |

## Kurulum

```bash
pip install ./sdks/python ./sdks/python-django
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız) |
| batch | PARTIAL (bellek içi kuyruk, kalıcı değil) |
| consent | SUPPORTED (yayınsız; istemci düzeyinde) |
| identity | SUPPORTED (yayınsız; identify çağrı başına ve varsayılan, group → fr_group, set_user_properties → fr_user_properties, set_global_properties/clear_global_properties; istemcide anahtar, değer ve kişisel veri süzgeci; toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar; birim testli ve gerçek collect e2e ile sınandı) |
| attribution | N/A |
| deeplink | N/A |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; verified yalnız sunucuda, makbuz doğrulayıcı BLOCKED_EXTERNAL) |
| error | PARTIAL (captureError → fr_error, Android ErrorEvent ile aynı gövde: temizlenmiş mesaj, parmak izi, en çok 5 konum; sınır ve örnekleme; pytest testli, sembolleştirme yok) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | PASS | Wheel run.mjs hedefinde kopyadan üretildi. |
| test | PASS | unittest 15/15; Django 6.1 sync ve async zincir. Django 4.2-5.x sınanmadı. |
| registry | PASS | PyPI'de yayımlandı: feralin-django==0.1.0 (19 Kasım 2026, git f519d767, twine; wheel ve sdist). Geri okuma: pypi.org JSON API iki dosyanın sha256 özeti yerel paketle aynı. Registry'den temiz kurulum: boş venv'e pip install feralin==0.1.0 feralin-django==0.1.0 feralin-fastapi==0.1.0 ve import feralin (Windows, Python 3.13); olay alındısı registry paketiyle koşulmadı. |
| clean_install | PASS | Çekirdek ve bağdaştırıcı wheel'leri temiz sanal ortama kuruldu; çerçeve PyPI'dan indi. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs python-django: Django test istemcisi, gerçek ara katman, gerçek toplayıcı. Gerçek WSGI/ASGI sunucusu NOT_RUN. |
| documentation | PASS | docs/sdk/python-django.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
