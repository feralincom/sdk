# Feralin Flutter örnek uygulaması

İzin, olay, gönderim ve durum akışını gösterir. Varsayılan olarak emülatörden ana makinedeki yerel collector'a bağlanır
(`10.0.2.2` emülatörde ana makinenin loopback adresidir; düz HTTP izni yalnız bu adres içindir).

```bash
flutter run \
  --dart-define=FERALIN_COLLECT_URL=http://10.0.2.2:4691 \
  --dart-define=FERALIN_PROJECT_KEY=pk_test_feralin_sample_local
```

Denemek için App Link:

```bash
adb shell am start -a android.intent.action.VIEW \
  -d "https://links.feralin.test/kampanya?fr_click=demo_1\&token=gonderilmez" com.feralin.feralin_flutter_example
```

`fr_click` yalnız "Analitik ve reklam ölçümüne izin ver" seçiliyken gider; "Yalnız analitiğe izin ver" ile `attribution_source=none` olur.

İzin kararı burada süreç ömrüyle sınırlıdır; gerçek uygulama kararı kendi deposunda veya CMP'sinde saklar ve her açılışta
`FeralinConfig.consent` ile bildirir. iOS hedefi bu örnekte yoktur (bkz. paket README'si).

## Emülatör uçtan uca senaryosu

`lib/e2e_main.dart` ayrı bir giriştir: başlatma, izinsiz olay yok, izin, ilk açılış (kurulum kaynağı), ekran, satın alma, ağ kesikken
kuyruk ve ağ geri gelince gönderim adımlarını kendiliğinden yürütür. `sdks/flutter/scripts/e2e-emulator.mjs` bu girişi derler, kendi
emülatöründe (port 5562) çalıştırır ve olayları gerçek toplayıcı, collect worker ve ClickHouse üzerinde doğrular. `git` ve `path`
kipleri aynı girişi `flutter create` ile açılan boş projeye, paketi pub.dev dışından ekleyerek koşar. Emülatördür, gerçek cihaz değildir;
adb ile kurulduğundan Play Install Referrer kanıtı yoktur ve kurulum kaynağı `none` beklenir.

```bash
DATABASE_URL='postgres://...' CLICKHOUSE_URL=http://127.0.0.1:18127 node sdks/flutter/scripts/e2e-emulator.mjs example
DATABASE_URL='postgres://...' CLICKHOUSE_URL=http://127.0.0.1:18127 node sdks/flutter/scripts/e2e-emulator.mjs git
```

Kanıt (video, son ekran, adımlar, ClickHouse çıktısı) git dışı `tests/e2e/screenshots/mobile/flutter-<kip>/` altına yazılır.
