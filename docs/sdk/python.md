<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Python: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/python/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | Python |
| Paket | `feralin` |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | REGISTRY_VERIFIED |
| Kaynak dizin | `sdks/python` |
| Registry | PyPI: **PUBLISHED** (sonraki adım: PyPI hesabı ve 2FA; ilk yayın pypi- önekli API anahtarıyla (twine, TWINE_PASSWORD) ya da pending trusted publisher; adlar feralin, feralin-django, feralin-fastapi boş (rezervasyon yok, ilk yayında alınır)) |
| Derleme | `python -m build sdks/python` |
| Test | `python -X utf8 -c "import sys,unittest; sys.path[:0]=['sdks/python/src','sdks/python/tests']; r=unittest.TextTestRunner().run(unittest.defaultTestLoader.discover('sdks/python/tests')); sys.exit(not r.wasSuccessful())"` |

## Kurulum

```bash
pip install -e sdks/python          # veya: PYTHONPATH=sdks/python/src
```

## İlk kullanım

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

```python
client.set_global_properties({"app_release": "2.4.0"})        # adı fr_ ile başlamayan her olaya eklenir; None anahtarı siler
client.set_user_properties({"plan": "pro"}, user_id="user_42")  # fr_user_properties; geçerli özellik yoksa None
client.group("acme-team", {"plan": "team"}, user_id="user_42")  # fr_group; geçersiz group_id → None
client.clear_global_properties()
```

```python
client = Client("pk_live_…", "https://collect.example.com", app_version="2.4.0", error_sample_rate=1.0)
try:
    charge()
except Exception as exc:
    client.capture_error(exc, user_id="user_42")  # varsayılan origin "handled"; izin yoksa ya da sınır aşıldıysa None
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
| build | PASS |  |
| test | PASS |  |
| registry | PASS | PyPI'de yayımlandı: feralin==0.1.0 (19 Kasım 2026, git f519d767, twine; wheel ve sdist). Geri okuma: pypi.org JSON API iki dosyanın sha256 özeti yerel paketle aynı. Registry'den temiz kurulum: boş venv'e pip install feralin==0.1.0 feralin-django==0.1.0 feralin-fastapi==0.1.0 ve import feralin (Windows, Python 3.13); olay alındısı registry paketiyle koşulmadı. |
| clean_install | PASS | Wheel temiz sanal ortama --no-index ile kuruldu. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs python: 202, outbox, izinsiz red, 401, idempotency. |
| documentation | PASS | docs/sdk/python.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
