# SDK sürüm desteği, LTS ve EOL politikası (F7-E06-T01)

Durum: **politika taslağı, ürün sahibi onayı bekliyor.** 17 Kasım 2026'da 10 npm paketi yayımlandı (`sdks/capabilities.yaml` içinde `registry.status: PUBLISHED`; `@feralin/react-native` 0.2.0, ötekiler 0.1.0; yaşam döngüsü `REGISTRY_VERIFIED` ya da `INSTALL_VERIFIED`, ayrıntı `docs/sdk/npm-yayin-adimlari.md`). Öteki kayıtlar `BLOCKED_EXTERNAL`; hiçbir kayıt `SUPPORTED` değildir ve hiçbir sürüm için destek süresi beyan edilmedi. Bu yüzden aşağıdaki destek süreleri ilk kararlı (`1.0.0`) yayınla başlar; bugün müşteriye destek taahhüdü verilmiş bir sürüm yoktur.

İlgili belgeler: `docs/sdk/release-checklist.md` (yayın kapısı ve geri alma), `docs/sdk/trusted-publishing.md` (OIDC yayın yolu), `docs/sdk/capability-matrix.md` §7 (zincir durumu).

## 1. Durum kaynakları

| Kaynak | Alan | Anlamı |
|---|---|---|
| `sdks/capabilities.yaml` | `version`, `version_sources`, `lifecycle`, `registry.status` | Kaynaktaki sürüm ve zincirin yerel kanıtla ulaştığı aşama. Destek tarihi taşımaz. |
| `sdk_releases` (migrasyon `0057`) | `support_until`, `deprecated_at`, `yanked_at`, `revoked_at`, `eol_at`, `release_status` | Sürüm başına destek bitişi (yönetici beyanı; boşsa bilinmiyor) ve yan yol işaretleri. Durum aşama kanıtından türetilir, elle yazılmaz. |
| `sdk_release_records` (migrasyon `0043`) | `action` (`yank`, `deprecate`, `advisory`), `advisory_id`, `severity` | Beyan günlüğü; geri çekme ve uyarılar buraya da düşer. |
| `GET /v1/sdk/releases` (üye kataloğu) | `support_until`, `recommended_version`, `yanked_versions`, `deprecated_versions`, `eol_versions`, sürüm satırında `eol` ve `eol_at`, `advisories` | Müşterinin gördüğü görünüm; kurulum sihirbazı ve MCP (`get_sdk_health`) aynı kaynaktan okur. EOL sürüm `eol_versions` içindedir, `deprecated_versions` içinde yer almaz. |

`support_until` yayın hattında iki yerde verilir: sürüm adayı açılırken (`POST /v1/admin/sdk/pipeline`, gövdede `support_until`) ve geri çekme/kullanımdan kaldırma eyleminde (`POST /v1/admin/sdk/pipeline/{id}/withdraw`, gövdede `support_until`; değer verilmezse eskisi korunur). Bu politikadaki tarih kuralı o alana yazılır; üye kataloğu sürüm satırında ve SDK özetinde gösterir. Uçtan uca sınaması: `services/saas-api/test/integration/sdk-release-drill.integration.spec.ts` (adım 1).

## 2. Sürüm numaralama

- SemVer: kırılan değişiklik major, geriye uyumlu özellik minor, düzeltme patch (`release-checklist.md` §2).
- `0.x` sürümler kararlı sayılmaz: destek süresi yoktur, yalnız en son `0.x` sürümü güvenlik yaması alır. `support_until` boş bırakılır ve katalogda "bilinmiyor" görünür.
- Sürüm tüm `version_sources` dosyalarında aynı olmalıdır (`scripts/sdk-dry-run/test` denetler).

## 3. Destek süreleri (`1.0.0` ve sonrası)

| Hat | Ne alır | Ne kadar |
|---|---|---|
| Güncel major | Özellik, hata düzeltmesi, güvenlik yaması | Yeni major yayımlanana kadar |
| Önceki major (LTS) | Yalnız güvenlik yaması ve veri kaybına yol açan kritik hata düzeltmesi | Yeni major'ın `REGISTRY_VERIFIED` olduğu günden itibaren 12 ay |
| Daha eski major | Hiçbir şey (EOL) | — |
| Aynı major içindeki eski minor | Yama almaz; kullanıcı aynı major'ın son minor'ına geçer | — |

Kurallar:

- Sürüm adayı açılırken `support_until` boş bırakılmaz: güncel major için "en erken 12 ay sonrası" yazılır, yeni major çıkınca önceki major'ın kayıtları `withdraw` (`deprecate`) ile güncellenir ve `support_until` = yeni major'ın doğrulanma tarihi + 12 ay olur.
- Destek süresi kısaltılmaz; uzatılabilir. Kısaltma yalnız güvenlik iptalinde (§5) olur.
- Mobil ve oyun SDK'larında mağaza ya da motor sürümü zorunluluğu (en düşük işletim sistemi, Unity sürümü) bu süreden önce gelebilir; o zaman EOL duyurusu (§4) zorunluluğun yürürlük tarihine bağlanır.

## 4. EOL duyurusu

1. En az 6 ay önce duyurulur. Duyuru kanalları: `/changelog` sayfası, paketin `CHANGELOG.md` ve README'si, SDK Merkezi'ndeki `support_until` tarihi, MCP `get_sdk_health` çıktısı. Registry'deki uyarı (`npm deprecate` ve benzeri) hesap açılınca eklenir; bugün `BLOCKED_EXTERNAL`.
2. E-posta duyurusu yoktur: e-posta sağlayıcısı bağlı değil (alt işleyen listesi, `/legal/subprocessors`).
3. Duyuru günü Super Admin yayın hattında ilgili sürümler `withdraw` → `deprecate` ile işaretlenir ve `support_until` EOL tarihine çekilir. `DEPRECATED` sürüm katalogda önerilmez (fail-closed, `sdk-integrity.service.ts`).
4. EOL tarihinde sürüm `EOL` durumuna geçer: Super Admin yayın hattında `withdraw` → `eol` (`POST /v1/admin/sdk/pipeline/{id}/withdraw`, gövdede `action: eol` ve gerekçe). Kurallar:
   - `eol_at` eylem anıyla bir kez yazılır ve kaldırılmaz. Gelecek tarihli EOL yazılmaz: planlanan EOL tarihi 3. adımda duyurulan `support_until` alanıdır.
   - `support_until` gelecekteyse eylem reddedilir (409 `sdk_release_support_active`): destek süresi kısaltılamaz (§3). Erken kapatma yalnız güvenlik iptalidir (§5). `support_until` boş olan sürümde (`0.x`, destek taahhüdü yok) EOL doğrudan yazılabilir.
   - Eylem `support_until`, `advisory_id` ve `severity` almaz (400): EOL bir destek kararıdır, uyarı değildir.
   - Yetki diğer `withdraw` eylemleriyle aynıdır: tek süper yönetici oturumu ve taze step-up; servis token'ı yazamaz. İki kişi onayı yayın içindir (§7), geri çekme ve EOL tek kişiyle yapılır. Eylem olay günlüğüne (`sdk_release_events`, `eol`) ve yönetici denetim kaydına (`sdk.release.eol`) düşer; beyan günlüğü (`sdk_release_records`) bu eylemi tanımaz.
   - Etkisi: sürüm `EOL` durumuna geçer, hiçbir yüzeyde önerilmez, yayın adımına giremez (409 `sdk_release_eol`). Üye kataloğunda `eol: true`, `eol_at` ve `eol_versions` ile görünür; `deprecated` false olur ve sürüm `deprecated_versions` listesinden çıkar (kullanımdan kaldırılan sürüm `support_until` tarihine kadar güvenlik yaması alır, EOL sürüm hiçbir şey almaz). MCP `get_sdk_health` sürümü `release_status: EOL`, `supported: false` döner.
   - Sınaması: `services/saas-api/test/integration/sdk-release-center.integration.spec.ts` ("destek sonu").

## 5. Güvenlik yaması kuralları

- Önem derecesi advisory kaydından gelir: `low`, `moderate`, `high`, `critical` (`withdraw` gövdesi ve `sdk_release_records.severity`).
- `high` ve `critical` advisory taşıyan sürüm hiçbir yüzeyde önerilmez (`sdk-integrity.service.ts`: `SEVERITY_RANK >= high` engelleyicidir).
- İstismar edilen ya da kimlik bilgisi sızdıran açıkta sürüm `security_revoke` ile iptal edilir; bu eylem advisory kimliği ve önem derecesi ister (sunucu reddeder). İptal edilen sürüm yeniden yayımlanamaz.
- Yama hedef süreleri (yayın hattında `REGISTRY_VERIFIED` olana kadar): `critical` 72 saat, `high` 7 gün, `moderate` bir sonraki planlı patch, `low` bir sonraki minor. Yama desteklenen her hatta (güncel major ve LTS) aynı anda çıkar.
- Yama da normal hattan geçer: kanıt paketi, SCA (`scripts/sdk-dry-run/sca.mjs`), maker-checker onayı, registry geri okuma. Acil durumda adımlar atlanmaz; yalnız bekleme süreleri kısalır.
- SCA bulgusunda Go standart kütüphane açığı SDK'da orta sayılır (`trusted-publishing.md` §2).

## 6. Yank ve hotfix tatbikatı

Amaç: yayımlanmış ve önerilen bir sürümün kritik hata yüzünden geri çekilmesi ve yama sürümünün aynı hattan çıkarılması adımlarının çalıştığını kanıtlamak. Gerçek registry hesabı olmadığından registry yerel sahte sunucudur; registry tarafındaki komutlar (`npm deprecate`, `npm unpublish` kısıtları, PyPI yank) tatbikata girmez ve `BLOCKED_EXTERNAL` kalır.

Adımlar:

1. Sürüm A hattan geçer: kanıt paketi → onay isteği (maker) → onay (checker, farklı yönetici, step-up) → `publish` (registry geri okuma) → `verify-registry` (özet eşleşmesi). A önerilen sürümdür; `support_until` katalogda görünür.
2. Olay: A'da kritik hata. Süper yönetici `withdraw` → `yank` (gerekçe, isteğe bağlı advisory ve önem derecesi). A hiçbir yüzeyde önerilmez, katalog `ATTENTION` döner, A yeniden yayımlanamaz (409), beyan günlüğüne ve yönetici denetim kaydına düşer.
3. Hotfix: A'nın patch sürümü B açılır ve aynı hattan geçer; isteyen kendi isteğini onaylayamaz (403). B `REGISTRY_VERIFIED` olunca önerilen sürüm olur; A geri çekilmiş kalır.
4. Duyuru: `/changelog` ve paket `CHANGELOG.md`'ye A'nın geri çekildiği, B'nin neyi düzelttiği yazılır (gerçek yayında).
5. Tatbikat sonu: test kaydı `deprecate` ile kapatılır, test veritabanında önerilen sürüm kalmaz.

Otomatik tatbikat (yalnız yerel test veritabanı):

```bash
cd services/saas-api
SAAS_API_TEST_DATABASE_URL="postgres://feralin_test:<yerel test parolası>@127.0.0.1:5432/<test DB>?sslmode=disable" \
  pnpm exec vitest run test/integration/sdk-release-drill.integration.spec.ts
```

Sıklık: her major yayından önce ve en az 6 ayda bir; sonuç bu bölümdeki kayda eklenir.

| Tarih | Commit tabanı | Sonuç | Not |
|---|---|---|---|
| 11 Kasım 2026 | `1576529` | 4/4 adım PASS | Yerel test DB (`feralin_test_v65` şablonu). `electron` SDK'sı, sahte npm registry. Registry tarafı komutları koşmadı (`BLOCKED_EXTERNAL`). |

## 7. Dual-control üretim yayını

Yayın onayı iki ayrı insan ister. Kanıt dosyaları:

| Kural | Nerede |
|---|---|
| İsteyen onaylayamaz; kaydı açan onaylayamaz; onay istek olmadan verilemez | `services/saas-api/migrations/0057_sdk_release_center.sql` (`CHECK approved_by <> requested_by`, `approved_by <> created_by`, `approved_by IS NULL OR requested_by IS NOT NULL`) |
| Kanıtı yükleyen onaylayamaz; yarış durumunda onay yeniden denetlenir; onay isteğinden sonra kanıt donar | `services/saas-api/src/modules/sdk-release-center/sdk-release-center.service.ts` (`SelfApprovalConflict`, `sdk_release_evidence_frozen`) |
| Yazma yalnız yönetici oturumu ve taze step-up ile; servis token'ı yazamaz | `sdk-release-center.controller.ts` (`@RequireStepUp`, `admin_session_required`) |
| Olay günlüğü değiştirilemez | `0057` (`sdk_release_events_immutable` tetikleyicisi) |
| Sınaması | `test/integration/sdk-release-center.integration.spec.ts` ("maker-checker", "dört göz", "özet uyuşmazlığı"), `test/integration/sdk-release-drill.integration.spec.ts` |

Sonuç: Super Admin yayın hattındaki onay kaydı dual-control'ü karşılar. Registry'ye asıl yükleme bu sunucudan yapılmaz; `.github/workflows/sdk-publish.yml` elle tetiklenir, `YAYINLA` onayı ve `sdk-release` ortamı ister. O ortamın zorunlu gözden geçireni GitHub ayarındadır ve depodan doğrulanamaz: yüklemenin ikinci onayı **`BLOCKED_EXTERNAL`** (hesap ve ortam ayarı yok).

## 8. Binary imzalama ve registry yayını

- **Arşiv imzalama aracı: kod tamam, anahtar ve güven kökü `BLOCKED_EXTERNAL`.** `scripts/sdk-signing/signing.mjs` (yalnız Node `crypto`, yeni bağımlılık yok) dağıtım arşivlerini Ed25519 ile imzalar ve doğrular: `keygen` (özel anahtar yalnız depo DIŞINDAKİ bir dosyaya, yalnız sahibi okuyacak izinle yazılır; depo içi yol ve üzerine yazma reddedilir), `sign` (özel anahtar yalnız `FERALIN_SDK_SIGNING_KEY` ortam değişkeninden ya da `FERALIN_SDK_SIGNING_KEY_FILE` yolundan okunur; çıktıya, loga ya da manifeste yazılmaz) ve `verify` (imza, güvenilen açık anahtar, iptal edilmiş anahtar, yank edilmiş sürüm, iki kişi onayı ve arşiv sha256 özetleri). Manifest DSSE zarfıdır: SDK, sürüm, arşiv adı/özet/boyut ve isteyen + onaylayan kişi. İsteyen ile onaylayan aynı kişiyse manifest üretilmez; elle üretilmiş aynı kişili manifest doğrulamada düşer (Super Admin hattındaki `approved_by <> requested_by` kuralının imza katmanındaki karşılığı). Sınaması: `node --test scripts/sdk-signing/test/signing.test.mjs` (yank tatbikatı ve anahtar dönüşümü dahil). Bu araç güven kökü KURMAZ: gerçek anahtarı ve onun saklanacağı yeri (CI sırrı ya da donanım anahtarı) ürün sahibi belirler; açık anahtar sürümle birlikte yayımlanır ve doğrulayana ayrıca iletilir.
- **Sigstore/OIDC (keyless) imza ve registry provenance: `BLOCKED_EXTERNAL`.** Gerekenler: CI koşucusunda Sigstore/npm provenance (OIDC) için registry hesabı ve trusted publisher tanımı, Maven Central için imza anahtarı, masaüstü ve mobil ikililer için platform imza sertifikaları. Hiçbiri yok. Bugün kanıt paketi geçici Ed25519 anahtarıyla DSSE imzalanır ve sunucuda `trust: ephemeral_dry_run` etiketiyle saklanır; bu bir güven kökü değildir.
- **Registry yayını: `BLOCKED_EXTERNAL`.** Gereken hesaplar ve doğrulama komutları `release-checklist.md` §3 tablosunda. Hesap açılınca yol `trusted-publishing.md` §3.
- Bu iki madde kalkmadan hiçbir sürüm `PUBLISHED` olamaz; `support_until` ve LTS süreleri yalnız kayıt düzeyinde kalır.

## 9. Açık kalanlar

- Duyuru süresinin (6 ay) sunucuda denetimi: `eol` eylemi yalnız `support_until` tarihinin geçmiş olmasına bakar; duyurunun en az 6 ay önce yapıldığı süreler onaylanana kadar süreçle sağlanır.
- EOL'ün panelde ayrı gösterimi: üye SDK ekranı `eol_versions` alanını henüz göstermiyor (API ve MCP döndürüyor).
- Registry tarafı yank/deprecate komutlarının tatbikatı (hesap gerekir).
- Ürün sahibinin bu belgedeki sürelere onayı (LTS 12 ay, duyuru 6 ay, yama hedefleri).
- EOL duyurusunun e-postayla gönderimi (e-posta sağlayıcısı yok).
