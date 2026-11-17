# Feralin Godot SDK

Godot 4 addon'u: UTP v1 olayları, izin öncelikli üretim, kalıcı şifreli kuyruk, idempotent batch gönderimi, gelir ve reklam geliri, oyun olayları, hata yakalama, atıf. Sözleşme Unity SDK 0.2.0 ile aynıdır.

> **Durum: `INTEGRATION_TESTED` (13 Kasım 2026, Godot 4.7.2, Windows, headless).** Çekirdek testleri 83/83 ve sözleşme testleri 362/362 geçti; `node scripts/sdk-e2e/run.mjs godot` addon'u boş projeye kurup HTTPRequest ile gerçek toplayıcıya oyun olayları, gelir ve reklam geliri gönderir, kalıcı şifreli kuyruğun yeniden açılışta aynı `event_id` ile tek outbox satırı ürettiğini doğrular. Android ve iOS yerel köprüleri (`native/`) derlenmedi; dışa aktarılmış oyuncu derlemesi, Web dışa aktarımı ve 4.7 dışındaki Godot sürümleri denenmedi. Registry'de yayınlanmadı.

## Kurulum

Registry yayını olmadığından addon depodan kopyalanır (`node scripts/sdk-e2e/run.mjs godot` boş projeye aynı kopyayla kurar). Addon herkese açık depoda `sdks/godot/addons/feralin` altındadır (<https://github.com/feralincom/sdk>); sürüm etiketi `sdks/godot/v0.2.0`. Yalnız addon dizinini indirmek için:

```bash
# OYUN_DIZINI oyununuzun project.godot dosyasının bulunduğu dizin
git clone --depth 1 --branch sdks/godot/v0.2.0 --filter=blob:none --sparse https://github.com/feralincom/sdk.git feralin-sdk
git -C feralin-sdk sparse-checkout set sdks/godot/addons/feralin
mkdir -p OYUN_DIZINI/addons
cp -r feralin-sdk/sdks/godot/addons/feralin OYUN_DIZINI/addons/feralin
```

Etiket depoya gönderilmeden `git clone --branch` "Remote branch not found" hatası verir; yayımlanmış etiketler <https://github.com/feralincom/sdk/tags> sayfasındadır. Git kullanmadan: aynı sayfada `sdks/godot/v0.2.0` etiketinin ZIP arşivi indirilir, içindeki `sdks/godot/addons/feralin` dizini aynı yere kopyalanır.

Bu depo kopyasından:

```bash
# Depo kökünden; OYUN_DIZINI oyununuzun project.godot dosyasının bulunduğu dizin
mkdir -p OYUN_DIZINI/addons
cp -r sdks/godot/addons/feralin OYUN_DIZINI/addons/feralin
```

1. `addons/feralin` dizinini oyunun `addons/` dizinine kopyalayın (yukarıdaki komut).
2. **Proje → Proje Ayarları → Eklentiler** içinden **Feralin**'i etkinleştirin. `Feralin` autoload'u eklenir.
3. **Proje Ayarları**'nda `feralin/project_key` (yalnız public `pk_`) ve `feralin/collect_url` alanlarını doldurun veya `Feralin.configure(...)` çağırın.

## En kısa örnek

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

## Yöntemler

| Yöntem | Görev |
|---|---|
| `track`, `identify`, `reset` | Serbest olay, kimlik |
| `track_revenue` | `feralin_purchase`: istemci beyanı, `verified` gönderilmez, tutar tam sayı küçük birim, makbuz isteğe bağlı |
| `track_ad_revenue` | `fr_ad_revenue`: `revenue_micros` (para biriminin milyonda biri), satın alma gelirinden ayrı |
| `track_level_start/complete/fail`, `track_economy_source/sink`, `track_rewarded_ad_shown/complete`, `track_iap_offer_shown/initiated` | Oyun olayları (`packages/schemas/utp/v1/game-events.md`); verilmeyen isteğe bağlı değer için `null` |
| `group`, `set_user_properties` | `fr_group`, `fr_user_properties` |
| `capture_error` | `fr_error`: kişisel veri ayıklanır, çerçeveler normalleştirilir, örnekleme ve dakikalık hız sınırı |
| `handle_deep_link`, `consume_deferred_deep_link` | `deep_link_opened`; Android Play Install Referrer'dan ertelenmiş yol |
| `bind_install` | iOS AdServices token'ı + rastgele kurulum kimliği (`install_bound` sinyali) |

## İzin

- Başlangıçta hiçbir izin yoktur; `analytics=false` iken hiçbir olay üretilmez, boş sözlük döner.
- `set_consent({"analytics": false})` bekleyen kuyruğu ve diskteki kalıcı kuyruğu da siler.
- `fr_click`, `utm_*`, Install Referrer ve AdServices yalnız `advertising=true` iken (iOS'ta ATT reddetmemişse) kullanılır.
- Analitik izniyle rastgele bir `anonymous_id` üretilip `user://feralin.cfg` içinde tutulur; izin geri çekilince ve `reset()` çağrısında silinir. `OS.get_unique_id()` kullanılmaz, parmak izi yoktur.
- JSON'a geçerli yazılamayan denetim karakteri içeren olay üretilmez; tek bozuk metin tüm batch'i düşürürdü.
- İzin kaydedilmez: oyun her açılışta kendi kararını bildirir. `verified`, `tenant_id`, `project_id` özellik olarak verilse bile çıkarılır.

## Kalıcı şifreli kuyruk

Olaylar `user://feralin/events.log` içinde AES-256-GCM ile şifreli tutulur (Android EncryptedEventStore ve Unity ile aynı satır biçimi: `enc1:` + hex(iv ‖ şifreli metin ‖ etiket), ilişkilendirilmiş veri olay kimliği). GCM, Godot `AESContext` ECB üstünde elle kurulmuştur (CTR + GHASH); olay başına birkaç milisaniye sürer. Süreç yeniden başlayınca izin verildiğinde aynı `event_id` ve aynı `Idempotency-Key` ile tekrar gönderilir. Kuyruk sınırı (varsayılan 1000) diske de uygulanır. Açılamayan satır atılır.

Veri anahtarı Android'de Keystore, iOS'ta Keychain ile korunur (yerel eklenti kuruluysa; derlenmedi); aksi halde `user://feralin/queue.key` dosyasında durur ve koruma düzeyi `local_file`dır. Anahtar alınamazsa düz metne düşülmez, kuyruk bellekte kalır. `configure(..., {"persist_queue": false})` kalıcılığı kapatır.

## Gönderim

- `Timer` her 2 sn'de bir, kuyruk batch boyutuna ulaşınca hemen gönderir.
- 202 → silinir. 401/403 → kuyruk atılır, oyun etkilenmez. Diğer 4xx (429 hariç) → o batch atılır. 429, 5xx ve ağ hatası → aynı içerik ve aynı `Idempotency-Key` ile üstel geri çekilmeyle (1 sn → 30 sn) denenir; `Retry-After` en çok 5 dakikaya kadar uygulanır.
- Odak kaybında, mobilde duraklatmada ve kapanış isteğinde gönderim denenir. 30 dakikalık otomatik oturum: arka planda süre dolarsa yeni `session_id`.

## Hata ve atıf notları

- `capture_error` elle çağrılır. GDScript ve motor hatalarını yakalayan kanca (`enable_log_error_capture()`) yalnız Godot 4.5+ `Logger` sınıfıyla çalışır; derlenmedi. Native çökme yakalanmaz.
- iOS'ta kesin tekil atıf iddia edilmez: sunucu bugün Apple'a sormaz, token yalnız saklanır. Ham URL saklanmaz; yalnız `fr_click` ve `utm_*` okunur.

## Desteklenmeyenler

- C# (`.NET`) Godot bağlaması, IAP doğrulaması (yalnız beyan), session replay, tracing.
- Web dışa aktarımında tarayıcı `User-Agent` başlığını değiştirmeye izin vermeyebilir; kalıcı kuyruk `user://` altında tarayıcı depolamasına bağlıdır; denenmedi.

## Test

Godot 4 kuruluysa:

```bash
godot --headless --path sdks/godot -s tests/test_feralin_core.gd
godot --headless --path sdks/godot -s tests/test_feralin_contracts.gd
```

Çıkış kodu kalan denetim sayısıdır; ancak Godot betik derleme hatasında da 0 ile çıkabildiği için `scripts/ci-local.sh --only sdk-godot` çıktıda `SCRIPT ERROR` ve özet satırını da denetler. Sözleşme testleri `tests/vectors/sdk_vectors.json` dosyasını kullanır (Unity çekirdeğinden üretilmiştir; Unreal SDK ile aynı dosya). Ağ katmanı (`feralin.gd`, HTTPRequest) birim testinde değil, `tests/e2e_consumer.gd` ile gerçek toplayıcıya karşı sınanır (`node scripts/sdk-e2e/run.mjs godot`). Yerel köprüler: `native/README.md`.
