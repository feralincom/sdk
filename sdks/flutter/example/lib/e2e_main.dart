// Emülatör uçtan uca senaryosu (QA-D): `sdks/flutter/scripts/e2e-emulator.mjs` bu girişi `-t lib/e2e_main.dart` ile derler.
// Akış: başlat → izinsiz olay yok → izin → ilk açılış (kurulum kaynağı) → ekran → satın alma → gönderim → ağ kesik →
// çevrimdışı kuyruk → ağ geri → gönderim. Her adım logcat'e `FR_E2E {json}` olarak yazılır ve ekranda listelenir;
// betik ağı bu satırlara göre keser ve açar. Sahte sonuç yok: gönderim gerçek toplayıcıya gider.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:feralin_flutter/feralin_flutter.dart';
import 'package:flutter/material.dart';

const String _collectUrl = String.fromEnvironment(
  'FERALIN_COLLECT_URL',
  defaultValue: 'http://10.0.2.2:4691',
);
const String _projectKey = String.fromEnvironment(
  'FERALIN_PROJECT_KEY',
  defaultValue: 'pk_test_feralin_sample_local',
);
const String _runId = String.fromEnvironment(
  'FERALIN_E2E_RUN',
  defaultValue: 'yerel',
);
// Kurulum eşleştirme kodu (panelin doğrulama ekranı üretir, tek kullanımlık). Boşsa SDK kod göndermez.
const String _installCode = String.fromEnvironment('FERALIN_INSTALL_CODE');

final ValueNotifier<List<String>> _lines = ValueNotifier<List<String>>([]);

void _report(String step, Map<String, Object?> data) {
  final line = jsonEncode({'step': step, ...data});
  debugPrint('FR_E2E $line');
  _lines.value = [..._lines.value, '$step ${jsonEncode(data)}'];
}

/// Toplayıcıya erişim; ağ durumu yalnız bununla anlaşılır (SDK'ya dokunulmaz).
Future<bool> _collectorReachable() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 2);
  try {
    final request = await client
        .getUrl(Uri.parse('$_collectUrl/v1/health'))
        .timeout(const Duration(seconds: 3));
    final response = await request.close().timeout(const Duration(seconds: 3));
    await response.drain<void>();
    return response.statusCode == 200;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _waitReachable(bool wanted) async {
  for (var i = 0; i < 60; i++) {
    if (await _collectorReachable() == wanted) return true;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return false;
}

/// `track` olayı SDK'nın iş sırasında kuyruğa yazar; kuyruk en az [atLeast] olaya varana kadar (en çok 15 sn) bekler.
Future<int> _waitQueued(int atLeast) async {
  for (var i = 0; i < 60; i++) {
    final queued = Feralin.getStatus().queued;
    if (queued >= atLeast) return queued;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return Feralin.getStatus().queued;
}

/// Kuyruk boşalana kadar gönderir. SDK ağ geri gelince kendisi de gönderebilir; o durumda açık çağrı boş kuyrukla 0 döner,
/// asıl kanıt kuyruğun boşalması ve ClickHouse satırıdır.
Future<FlushResult> _drain() async {
  var last = FlushResult.none;
  for (var i = 0; i < 20; i++) {
    final result = await Feralin.flush();
    if (result.status != 0) last = result;
    if (Feralin.getStatus().queued == 0) break;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return last;
}

Future<void> _scenario() async {
  final ready = await Feralin.initialize(
    const FeralinConfig(
      projectKey: _projectKey,
      collectUrl: _collectUrl,
      debug: true,
      installCode: _installCode == '' ? null : _installCode,
    ),
  );
  var status = Feralin.getStatus();
  _report('initialize', {
    'ready': ready,
    'sdk': status.sdk,
    'version': status.version,
    'run': _runId,
  });
  if (!ready) throw StateError('SDK başlatılamadı');

  // İzin kararı yokken olay üretilmez ve kuyruğa girmez.
  final denied = Feralin.track('e2e_before_consent');
  _report('izin-yok', {
    'event_id': denied,
    'queued': Feralin.getStatus().queued,
  });

  // Reklam ölçümü izniyle kurulum kaynağı (Play Install Referrer) okunur; adb kurulumunda kanıt yoktur.
  await Feralin.setConsent(const Consent(analytics: true, advertising: true));
  await Future<void>.delayed(const Duration(seconds: 3));
  status = Feralin.getStatus();
  _report('izin', {
    'analytics': status.consent?.analytics,
    'advertising': status.consent?.advertising,
    'anonymous_id': status.anonymousId,
    'queued': status.queued,
  });

  final screen = Feralin.screen('e2e_home', {'run': _runId});
  final purchase = Feralin.trackRevenue(
    RevenueInput(
      transactionId: 'e2e_flutter_${_runId}_1',
      amountMinor: 4999,
      currency: 'TRY',
      productId: 'e2e_pro_monthly',
      purchaseType: PurchaseType.subscriptionStart,
    ),
  );
  // İlk açılış + ekran + satın alma; ilk açılış referrer okunduktan sonra kuyruğa girer.
  final pending = await _waitQueued(3);
  final online = await _drain();
  _report('cevrimici-ilk', {
    'screen_event_id': screen,
    'purchase_event_id': purchase,
    'pending': pending,
    'status': online.status,
    'batch_id': online.batchId,
    'queued': Feralin.getStatus().queued,
  });

  _report('wait-offline', {});
  final wentOffline = await _waitReachable(false);
  final offlineEvent = Feralin.trackRevenue(
    RevenueInput(
      transactionId: 'e2e_flutter_${_runId}_2',
      amountMinor: 1999,
      currency: 'TRY',
      productId: 'e2e_coins_500',
    ),
  );
  await _waitQueued(1);
  final offlineFlush = await Feralin.flush();
  _report('cevrimdisi', {
    'network_off': wentOffline,
    'event_id': offlineEvent,
    'status': offlineFlush.status,
    'queued': Feralin.getStatus().queued,
  });

  _report('wait-online', {});
  final backOnline = await _waitReachable(true);
  final after = await _drain();
  _report('cevrimici', {
    'network_on': backOnline,
    'event_id': offlineEvent,
    'status': after.status,
    'queued': Feralin.getStatus().queued,
  });
  _report('done', {});
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _E2EApp());
  try {
    await _scenario();
  } on Object catch (error) {
    _report('error', {'message': error.toString()});
  }
}

class _E2EApp extends StatelessWidget {
  const _E2EApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Feralin E2E',
      home: Scaffold(
        appBar: AppBar(title: const Text('Feralin Flutter E2E')),
        body: ValueListenableBuilder<List<String>>(
          valueListenable: _lines,
          builder: (context, lines, _) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(line, style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
