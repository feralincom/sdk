<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Godot GDScript: kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/godot/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | GDScript |
| Paket | `feralin` |
| Sürüm | 0.2.0 |
| Yaşam döngüsü | INTEGRATION_TESTED |
| Kaynak dizin | `sdks/godot` |
| Registry | Godot Asset Library: **BLOCKED_EXTERNAL** (gereken: Herkese açık depo github.com/feralincom/sdk var; addon sdks/godot/addons/feralin etiketten kopyalanır, güncel içeriğin gönderimi ve sdks/godot/v0.2.0 etiketi (site sahibinin onayı, docs/sdk/git-yayin-adimlari.md). Godot Asset Library kaydı ayrı hesap ister) |
| Test | `godot --headless --path sdks/godot -s tests/test_feralin_core.gd && godot --headless --path sdks/godot -s tests/test_feralin_contracts.gd` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `Godot Asset Library` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```bash
# OYUN_DIZINI oyununuzun project.godot dosyasının bulunduğu dizin
git clone --depth 1 --branch sdks/godot/v0.2.0 --filter=blob:none --sparse https://github.com/feralincom/sdk.git feralin-sdk
git -C feralin-sdk sparse-checkout set sdks/godot/addons/feralin
mkdir -p OYUN_DIZINI/addons
cp -r feralin-sdk/sdks/godot/addons/feralin OYUN_DIZINI/addons/feralin
```

```bash
# Depo kökünden; OYUN_DIZINI oyununuzun project.godot dosyasının bulunduğu dizin
mkdir -p OYUN_DIZINI/addons
cp -r sdks/godot/addons/feralin OYUN_DIZINI/addons/feralin
```

## İlk kullanım

```gdscript
func _ready() -> void:
	Feralin.configure("pk_live_ORNEK", "https://collect.ornek.com")
	# Karar oyunun izin ekranından gelir; SDK izni kendisi varsaymaz ve saklamaz.
	Feralin.set_consent({"analytics": true})
	Feralin.track_level_start("dunya_1", 1)
	Feralin.track_revenue({"transaction_id": "tx_1001", "amount_minor": 4999, "currency": "TRY", "product_id": "gold_pack"})
	Feralin.flush()
	var result: Dictionary = await Feralin.flushed
	print(result["status"], " ", result["retained"])
```

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | SUPPORTED (yayınsız; Godot 4.7 headless ile gerçek toplayıcıya sınandı, oyuncu derlemesi yok) |
| batch | PARTIAL (kalıcı şifreli kuyruk user://feralin altında AES-256-GCM, Unity ve Android ile aynı enc1 satır biçimi, yeniden açılışta aynı event_id ile tek outbox satırı gerçek toplayıcıyla sınandı; Android Keystore ve iOS Keychain köprüleri derlenmedi, masaüstünde anahtar dosyada (local_file)) |
| consent | SUPPORTED (yayınsız; izin kapısı, izin çekilince bellek ve disk kuyruğu silinir; birim ve e2e testli) |
| identity | PARTIAL (identify, reset, rastgele anonymous_id, group ve setUserProperties fr_group ve fr_user_properties olayıdır, 30 dakikalık otomatik oturum; birim testli, toplayıcı yalnız projenin izin listesindeki anahtarları saklar ve ClickHouse kimlik projeksiyonuna yazar) |
| attribution | PARTIAL (Android Play Install Referrer ve iOS AdServices BindInstall çekirdek mantığı birim testli; yerel köprüler derlenmedi ve cihazda sınanmadı; iOS kesin tekil atıf değildir, ATT reddi reklam kanıtını kapatır, parmak izi yok) |
| deeplink | PARTIAL (handle_deep_link ile deep_link_opened ve ertelenmiş yol; birim testli, cihazda ve gerçek App Link ile sınanmadı) |
| revenue | PARTIAL (track_revenue → feralin_purchase istemci beyanı, verified gönderilmez; fr_ad_revenue (revenue_micros) ve oyun olayları gerçek toplayıcıyla sınandı; makbuz doğrulayıcı BLOCKED_EXTERNAL) |
| error | PARTIAL (fr_error, PII temizliği, çerçeve parmak izi, örnekleme ve hız sınırı birim testli; günlük kancası yalnız Godot 4.5+ Logger ile ve bu koşuda sınanmadı; native çökme yakalanmaz) |
| replay | N/A |
| tracing | PLANNED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS | 0.2.0 addon ve testler; ilk gerçek koşuda iki GDScript tür çıkarımı hatası (feralin_store.gd) ve boş girdide SHA-256 hatası düzeltildi. Android ve iOS yerel köprü kaynakları derlenmedi. |
| build | PASS | Godot 4.7.2 (Windows, headless) addon betiklerini hatasız derledi. Dışa aktarılmış oyuncu derlemesi (Windows, Android, iOS, Web) yapılmadı; 4.7 dışındaki sürümler denenmedi. |
| test | PASS | godot --headless: çekirdek 83/83, sözleşme 362/362 denetim (NIST AES-256-GCM, Unity vektörleri, kalıcı şifreli kuyruk, gelir, oyun olayları, hata, oturum, atıf, BindInstall). İki test hatası test kodundaydı (lambda yakalaması, genel hata sınırı senaryosu) ve Unity testiyle hizalandı. |
| registry | BLOCKED_EXTERNAL | 17 Kasım 2026: Asset Library hesabı yok; Git etiketi sdks/godot/v0.2.0 gönderilmedi. |
| clean_install | PASS | scripts/sdk-e2e/targets/godot.mjs: addons/feralin boş Godot projesine kopyalanıp autoload'suz yüklendi; Asset Library'den kurulum denenemez. |
| event_receipt | PASS | scripts/sdk-e2e/run.mjs godot: HTTPRequest ile gerçek services/collect + PostgreSQL outbox; 9 olay (level_start/complete/fail, economy_source/sink, rewarded_ad_shown/complete, feralin_purchase verified'sız, fr_ad_revenue) tek outbox satırı ve platform=godot, özellikler ve session_id denetlendi; kapalı adreste kalan olay yeniden açılışta şifreli kuyruktan aynı event_id ile tek satır. Editor/headless içindedir, cihaz değildir. |
| documentation | PASS | docs/sdk/godot.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
