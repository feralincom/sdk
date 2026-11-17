<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# FastAPI: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/python-fastapi/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Python |
| Paket | `feralin-fastapi` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/python-fastapi` |
| Registry | PyPI: **BLOCKED_EXTERNAL** (gereken: PyPI hesabı, 2FA, API token; feralin çekirdeğinin yayını) |
| Derleme | `python -m build sdks/python-fastapi` |
| Test | `node scripts/sdk-dry-run/python-adapter.mjs sdks/python-fastapi fastapi httpx` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `PyPI` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
pip install ./sdks/python ./sdks/python-fastapi fastapi
```

## İlk kullanım

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
| test | PASS | unittest 14/14; FastAPI 0.162, Starlette 1.10. |
| registry | BLOCKED_EXTERNAL | PyPI hesabı yok; feralin çekirdeği de yayınlanmadı. |
| clean_install | PASS | Çekirdek ve bağdaştırıcı wheel'leri temiz sanal ortama kuruldu; çerçeve PyPI'dan indi. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs python-fastapi: TestClient, gerçek ASGI zinciri, gerçek toplayıcı. Gerçek uvicorn süreci NOT_RUN. |
| documentation | PASS | docs/sdk/python-fastapi.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
