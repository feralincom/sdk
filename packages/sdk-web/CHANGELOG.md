# Değişiklik günlüğü

`@feralin/web@0.2.0` yayın adayıdır; `@feralin/web@0.1.0` npm'de yayımlıdır (17 Kasım 2026, git b1a7d127); site ayrıca `/sdk/feralin.iife.js` ile sunar. Doğrulama durumu `sdks/capabilities.yaml` içindedir.

## 0.2.0 (yayın adayı, 25 Kasım 2026)

Ekleyici sürüm: 0.1.0'daki hiçbir dışa açık API kaldırılmadı ya da değişmedi.

- Kısa link kodu: giriş sayfasının adresindeki `fr_link` korunur ve olay özelliğine taşınır; link yönlendiricisi web hedefine bu kodu ekler (18 Kasım 2026).
- Yönlendiren ayrıntısı: `page_view` olayında `referrer_path` (yönlendiren sayfanın yolu, sorgusuz) ve bilinen arama motorlarından gelen `search_query` (temizlenmiş, kısaltılmış); liste toplayıcının listesiyle aynıdır (20 Kasım 2026).
- `@feralin/web/smart` (Smart Script, ayrı giriş noktası, çekirdek bütçesine girmez): açılış sayfasındaki mağaza bağlantılarını Feralin kısa linkine çevirir ve sayfanın UTM ve reklam tıklama kimliklerini linke ekler; çerez yazmaz, parametreler yalnız oturum boyunca `sessionStorage` içinde tutulur. `smart/snippet` IIFE olarak da sunulur (19 Kasım 2026).
- Kurulum belgeleri gerçek toplayıcı adresini verir (`https://feralin.com/collect`).
- Sayfada görünür süre: çekirdek her `page_view` için sekmenin görünür olduğu süreyi ölçer ve `fr_page_engagement` {`visible_ms`} olarak gönderir (sekme gizlenince, sayfa kapanırken ve sonraki `page_view`'dan önce; ölçülen sayfanın adresi, başlığı ve oturumuyla). Arka plandaki sekme sayılmaz, oturumun son sayfası ölçülür. `pageEngagement: false` kapatır; `PAGE_ENGAGEMENT_EVENT_NAME` dışa aktarılır (19 Kasım 2026).
- `@feralin/web/errors`: V8 yığın izinin `Tür: mesaj` başlığı mesajında `@` varsa (ör. e-posta) Firefox çerçevesi sanılıp `top_frame` ve parmak izine giriyordu; V8 biçiminde artık yalnız `at ` satırları okunur. Toplayıcı `top_frame` alanını sunucuda da temizlediği için saklanan veriye e-posta yazılmıyordu; düzeltme istemciden çıkışı da keser (17 Kasım 2026).

## 0.1.0 (npm'de yayımlı, 17 Kasım 2026, git b1a7d127)

- Kurulum eşleştirme kodu: `new Feralin({ ..., installCode })` panelin "Kurulumu doğrula" ekranındaki tek kullanımlık kodu izin sonrası ilk olaya `fr_install_code` olarak ekler; biçimi geçersiz kod yok sayılır (16 Kasım 2026).
- UTP v1 çekirdeği: `initialize`, `track`, `identify`, `reset`, `setConsent`, `flush`; ULID olay kimliği, `localStorage` kuyruğu (yoksa bellek), batch gönderimi `POST /v1/batch` (3 Kasım 2026).
- İzin ve atıf düzeltmeleri: izin kararı olmadan olay üretilmez, `fr_click` yalnız reklam izniyle taşınır, URL'den yalnız izin listesindeki `utm_*` okunur (3 Kasım 2026).
- App Banner betiği (`banner`): mobil web sayfasında Smart Link'e götüren şerit; çerez yazmaz, olay göndermez (5 Kasım 2026).
- Çekirdek dayanıklılığı: üstel geri çekilmeye jitter, güvenlik bulgularının düzeltmeleri (6 Kasım 2026).
- `@feralin/web/replay` (yalnız tıklama, kaydırma ve görünüm etkileşimi; DOM kaydı, metin ve form değeri yok, maskeleme kapatılamaz) ve `@feralin/web/flags` (özellik bayrakları ve deneyler) alt modülleri (9 Kasım 2026).
- `trackRevenue` → `feralin_purchase` istemci beyanı; doğrulanmış gelir yalnız sunucuda (10 Kasım 2026).
- `@feralin/web/auto`: tek sayfalı uygulamada `page_view`, dış bağlantı, dosya indirme, 404 ve (varsayılan kapalı) site içi arama olayları; sorgu dizgisi olaylara girmez (12 Kasım 2026).
- `@feralin/web/errors`: `window` hata ve `unhandledrejection` → `fr_error`, parmak izi, örnekleme ve hız sınırı (12 Kasım 2026).
- Sekme güvenli kuyruk: kuyruk her işlemde depodan okunur; bir sekme diğerinin gönderilmemiş olayını silmez, onaylanan olayı yeniden göndermez, aynı `event_id` iki kez eklenmez (12 Kasım 2026).
- Kimlik yöntemleri (UTP §8.2): `group` → `fr_group`, `setUserProperties` → `fr_user_properties`, `setGlobalProperties` ve `clearGlobalProperties`; kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer istemcide düşer. React, Vue, Angular ve Tauri tutamağı da aynı yöntemleri taşır (13 Kasım 2026).
