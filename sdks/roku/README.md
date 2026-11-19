# Feralin Roku SDK (BrightScript)

Roku kanalları için Feralin ölçüm SDK'sı. SceneGraph `Task` düğümünde çalışır: olaylar UTP v1 sözleşmesiyle (`packages/schemas/utp/v1`) `POST /v1/batch` üzerinden gider; kuyruk cihazın kayıt bölümünde (`roRegistrySection`) tutulur, ağ hatasında aynı `Idempotency-Key` ile geri çekilerek yeniden denenir. Hiçbir işlev kanalı durdurmaz.

## Durum

| Konu | Durum |
|---|---|
| Çekirdek mantık (`FeralinCore.brs`) | 99 birim testi geçiyor: `brs` yorumlayıcısı (npm `brs@0.45.0`, depoya bağımlılık olarak eklenmez), sahte cihaz, kayıt bölümü ve saat |
| Batch gövdesinin toplayıcı şemasıyla denetimi | `platform: "roku"` (varsayılan) ve `platform: "other"` gövdeleri toplayıcı şemasına uyuyor |
| Task iş parçacığı (`FeralinTask.brs`) ve uygulama yüzü (`FeralinApi.brs`) | Yalnız sözdizimi denetlendi; `roUrlTransfer`, `roRegistrySection`, Task ve `m.global` gerçek Roku cihazı ister: **cihazda çalıştırılmadı** |
| Olayın toplayıcıya ulaşması | **Sınanmadı**: Roku cihazı (geliştirici modu) gerekir |
| Kanal mağazası / dağıtım | Yok; dosyalar kanalın kaynak ağacına kopyalanır |

### Toplayıcı sözleşmesi: `platform = "roku"`

Toplayıcının olay şeması (`services/collect/internal/schema/event.schema.json` ve kanonik kopyası `packages/schemas/utp/v1/event.schema.json`) `platform` için kapalı bir liste kullanır; `roku` bu listeye 19 Kasım 2026'da eklendi. Bu değişiklik canlıya dağıtılmadan önceki bir toplayıcı `roku` gövdesini `400` ile reddeder; o durumda geçici olarak `platform: "other"` verilebilir.

## Kurulum

`components/feralin/` klasörünü kanalınızın `components/` dizinine kopyalayın. Sahne bileşeninizin XML dosyasına uygulama yüzünü ekleyin:

```xml
<script type="text/brightscript" uri="pkg:/components/feralin/FeralinApi.brs" />
```

## Kullanım

```brightscript
sub init()
    Feralin_Init({
        projectKey: "pk_live_...",                  ' yalnız public anahtar; sk_ reddedilir
        collectUrl: "https://collect.example.com",
        consent: KayitliIzin()                      ' { analytics: true, advertising: false } ya da invalid (bekleniyor)
    })
    Feralin_Track("video_start", { title_id: "t1" })
    Feralin_Screen("home")
    Feralin_Identify("kullanici_42")                ' PII vermeyin
    Feralin_TrackRevenue({ transactionId: "order_1", amountMinor: 4999, currency: "TRY" })
end sub
```

| İşlev | Davranış |
|---|---|
| `Feralin_Init(config)` | Task düğümünü kurar ve `m.global.feralinTask` alanına koyar; her bileşen aynı örneği kullanır |
| `Feralin_SetConsent(consent)`, `Feralin_OptOut()` | `analytics=false`: kuyruk ve kimlikler silinir. Reklam izni kalkarsa bekleyen olaylardan reklam ve tıklama kimliği çıkarılır |
| `Feralin_Track`, `Feralin_Screen`, `Feralin_TrackRevenue` | Olay üretir; izin yoksa (bekleniyor ya da `analytics=false`) olay üretilmez |
| `Feralin_Identify`, `Feralin_Reset` | Kullanıcı kimliği; `Reset` kimlikleri yeniler ve kuyruğu siler |
| `Feralin_Flush()`, `Feralin_Status()` | Hemen göndermeyi dener; son durum (`queued`, `lastResult`) |

### Otomatik olaylar

- `app_first_open`: analitik izni olan ilk çalıştırmada, kurulum başına bir kez (`os_version`, `device_model`).
- `session_start`: yeni oturumda; son etkinlikten `sessionTimeoutSeconds` (varsayılan 1800) geçince yeni `session_id` üretilir.

### Reklam kimliği (RIDA)

RIDA yalnız üç koşul birlikte sağlanınca okunur ve yalnız `app_first_open` olayına eklenir: kanal `collectAdvertisingId: true` ile açıkça ister, kullanıcı reklam ölçümü iznini verir (`consent.advertising = true`) ve cihazda "Limit ad tracking" kapalıdır (`roDeviceInfo.IsRIDADisabled()` false). Aksi hâlde `GetRIDA()` hiç çağrılmaz. Uygulamanın kendi `advertising_id` özelliği her olaydan çıkarılır. AB kullanıcılarında GDPR yükümlülükleri kanal sahibinindir.

### Yapılandırma

| Alan | Varsayılan | Not |
|---|---|---|
| `batchSize` | 20 | 1-100 |
| `flushIntervalMs` | 10000 | 1000-300000 |
| `queueLimit` | 100 | 1-200 olay |
| `maxQueueChars` | 16000 | Kuyruk JSON metni üst sınırı; kayıt bölümü kanal başına sıkıştırılmış 32 KB'tır ve kanalın kendi verisiyle paylaşılır |
| `sessionTimeoutSeconds` | 1800 | 60-86400 |
| `requestTimeoutMs` | 15000 | Yanıt gelmeyen istek iptal edilir ve yeniden denenir |
| `installCode` | yok | Panelin "Kurulumu doğrula" kodu; ilk olaya `fr_install_code` |
| `appVersion` | `roAppInfo.GetVersion()` | `context.app.version` |

## Testler

```bash
node sdks/roku/tests/run.mjs        # npx --yes brs@0.45.0 indirir; BRS_BIN ile yerel brs verilebilir
```

Testler `FeralinCore.brs` mantığını sınar ve üretilen batch gövdelerini toplayıcı şemasıyla (`ajv`, packages/sdk-web geliştirme bağımlılığı) doğrular. Task iş parçacığı, `roUrlTransfer`, kayıt bölümüne gerçek yazım ve `m.global` cihazda sınanmalıdır.

## Kaynaklar

Kullanılan Roku API'leri developer.roku.com belgeleriyle doğrulandı; adresler kaynak dosyaların başındaki yorumlardadır (ifdeviceinfo, ifurltransfer, ifhttpagent, rourlevent, ifregistrysection, roregistry, iftimespan, ifdatetime, task, threads, brightscript-support, interface, ifsgnodefield).

## English

BrightScript SDK for Roku channels. A SceneGraph `Task` node owns networking (`roUrlTransfer` is Task-only), an on-device queue in `roRegistrySection`, batching, and retries with exponential backoff and a stable `Idempotency-Key`. It emits `app_first_open` once per install, `session_start` on new sessions, and `track`/`screen`/`identify`/`trackRevenue` events, all gated on consent. The Roku advertising ID (RIDA) is read only when the channel opts in (`collectAdvertisingId: true`), the user granted advertising consent, and `IsRIDADisabled()` is false; it is attached only to `app_first_open`.

Status: 99 core unit tests pass under the `brs` interpreter (no device), and the generated batches validate against the collector schema with `platform: "roku"` (default) and `platform: "other"`. `roku` was added to the collector's platform enum on 19 November 2026; a collector deployed before that rejects it, in which case pass `platform: "other"`. The Task thread and render-thread API are only syntax-checked; nothing has run on a Roku device.
