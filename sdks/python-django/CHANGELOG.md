# Değişiklik günlüğü

Paket PyPI'a yayınlanmadı: hesap yok ve `feralin` çekirdeği de yayınlanmadı (`BLOCKED_EXTERNAL`). Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## 0.1.0 (yayınlanmadı)

- `feralin` çekirdeği üstünde Django ara katmanı (`feralin_django.FeralinMiddleware`): her isteğe `request.feralin` eklenir, izin ve kimlik o isteğin kullanıcısından alınır; WSGI ve ASGI (sync ve async zincir) (6 Kasım 2026).
- Paket derlemesi çalışma ağacını kirletmez (derleme çıktıları yok sayılır) (6 Kasım 2026).
