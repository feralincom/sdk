<!-- GENERATED: scripts/sdk-dry-run/docs.mjs (elle düzenlemeyin; sdks/capabilities.yaml ve SDK README'sinden üretilir) -->

# Roku (BrightScript): kurulum ve durum

> Bu belge `sdks/capabilities.yaml` ve `sdks/roku/README.md` dosyalarından üretilir. Durumlar yalnız gerçekten koşulmuş testlere dayanır; `PASS` yerel kanıttır, registry yayını ve Super Admin kanıtı ayrı halkalardır.

## Özet

| Alan | Değer |
|---|---|
| Dil | BrightScript |
| Paket | yok (kaynak dizin) |
| Sürüm | 0.1.0 |
| Yaşam döngüsü | UNIT_TESTED |
| Kaynak dizin | `sdks/roku` |
| Registry | Yok (kanal kaynak ağacına kopyalanır): **BLOCKED_EXTERNAL** (gereken: Dağıtım biçimi kararı (kaynak kopyası ya da Roku bileşen kitaplığı) ve gerçek Roku cihazı) |
| Test | `node sdks/roku/tests/run.mjs` |

## Kurulum

Registry yayını durumu **BLOCKED_EXTERNAL**: paket henüz `Yok (kanal kaynak ağacına kopyalanır)` üzerinde yayınlanmış olarak doğrulanmadı; aşağıdaki adımlar kaynaktan ya da yerel pakettendir.

```xml
<script type="text/brightscript" uri="pkg:/components/feralin/FeralinApi.brs" />
```

## İlk kullanım

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

## Yetenekler

| Yetenek | Durum |
|---|---|
| event | PARTIAL (track, screen, app_first_open, session_start; brs ile testli, cihazda koşmadı; platform=roku toplayıcı şemasında) |
| batch | PARTIAL (roRegistrySection kalıcı kuyruğu, sayı ve boyut sınırı, aynı Idempotency-Key ile üstel geri çekilme ve Retry-After; brs ile testli, cihazda koşmadı) |
| consent | PARTIAL (bekleniyor, analytics=false, reklam izni geri çekme; brs ile testli) |
| identity | PARTIAL (identify, reset; anonim kimlik kayıt bölümünde; brs ile testli) |
| attribution | PARTIAL (RIDA yalnız collectAdvertisingId=true, consent.advertising=true ve IsRIDADisabled()=false iken app_first_open olayında; kurulum kodu; brs ile testli, cihazda koşmadı) |
| deeplink | UNSUPPORTED |
| revenue | PARTIAL (trackRevenue → feralin_purchase istemci beyanı; brs ile testli) |
| error | UNSUPPORTED |
| replay | N/A |
| tracing | UNSUPPORTED |

## Doğrulama zinciri

| Halka | Durum | Not |
|---|---|---|
| source | PASS |  |
| build | NOT_APPLICABLE | BrightScript derlenmez; Task ve uygulama yüzü dosyaları brs ile ayrıştırıldı. Cihaza yükleme (sideload) yapılmadı. |
| test | PASS | node sdks/roku/tests/run.mjs (19 Kasım 2026): brs@0.45.0 yorumlayıcısında 99/99 çekirdek testi; üretilen batch gövdesi platform=roku ve platform=other ile toplayıcı şemasından geçti. Task iş parçacığı, roUrlTransfer ve gerçek kayıt bölümü cihazda sınanmadı. |
| registry | NOT_APPLICABLE | Paket kayıt defteri yok. |
| clean_install | NOT_RUN | Boş Roku kanalına kopyalayıp cihaza yükleme denenmedi. |
| event_receipt | BLOCKED_EXTERNAL | Roku cihazı (geliştirici modu) gerekir. |
| documentation | PASS | docs/sdk/roku.md: kurulum ve kullanım kod blokları README'den, yetenek ve zincir durumu yetenek dosyasından üretilir (scripts/sdk-dry-run/docs.mjs); registry yayını ve Super Admin kanıtı ayrı halkadır. |
| super_admin_proof | NOT_STARTED |  |
