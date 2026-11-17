import 'dart:ui' show PlatformDispatcher;

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

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // `consent` verilmez: karar gelene kadar olay üretilmez ve gönderilmez.
  await Feralin.initialize(
    const FeralinConfig(
      projectKey: _projectKey,
      collectUrl: _collectUrl,
      debug: true,
    ),
  );
  runApp(const SampleApp());
}

class _Texts {
  const _Texts({
    required this.title,
    required this.grant,
    required this.grantAd,
    required this.deny,
    required this.track,
    required this.flush,
    required this.pending,
    required this.consent,
    required this.advertising,
    required this.queued,
    required this.lastSend,
    required this.notSent,
    required this.accepted,
    required this.rejected,
  });

  final String title;
  final String grant;
  final String grantAd;
  final String deny;
  final String track;
  final String flush;
  final String pending;
  final String consent;
  final String advertising;
  final String queued;
  final String lastSend;
  final String notSent;
  final String accepted;
  final String rejected;

  static const _Texts en = _Texts(
    title: 'Feralin Sample',
    grant: 'Allow analytics only',
    grantAd: 'Allow analytics and ad measurement',
    deny: 'Deny analytics',
    track: 'Send test event',
    flush: 'Send queue now',
    pending: 'pending',
    consent: 'Consent',
    advertising: 'Ad measurement',
    queued: 'Queued events',
    lastSend: 'Last send',
    notSent: 'not sent yet',
    accepted: 'accepted',
    rejected: 'rejected',
  );

  static const _Texts tr = _Texts(
    title: 'Feralin Örnek',
    grant: 'Yalnız analitiğe izin ver',
    grantAd: 'Analitik ve reklam ölçümüne izin ver',
    deny: 'Analitiği reddet',
    track: 'Deneme olayı gönder',
    flush: 'Kuyruğu şimdi gönder',
    pending: 'bekleniyor',
    consent: 'İzin',
    advertising: 'Reklam ölçümü',
    queued: 'Kuyruktaki olay',
    lastSend: 'Son gönderim',
    notSent: 'henüz gönderilmedi',
    accepted: 'kabul',
    rejected: 'ret',
  );

  static _Texts get current =>
      PlatformDispatcher.instance.locale.languageCode == 'tr' ? tr : en;
}

class SampleApp extends StatelessWidget {
  const SampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(title: _Texts.current.title, home: const SampleHome());
  }
}

class SampleHome extends StatefulWidget {
  const SampleHome({super.key});

  @override
  State<SampleHome> createState() => _SampleHomeState();
}

class _SampleHomeState extends State<SampleHome> {
  FlushResult? _lastFlush;

  Future<void> _decide(Consent consent) async {
    await Feralin.setConsent(consent);
    setState(() {});
  }

  void _track() {
    Feralin.track('sample_button_clicked', {'screen': 'main'});
    setState(() {});
  }

  Future<void> _flush() async {
    final result = await Feralin.flush();
    debugPrint(
      'FeralinSample flush status=${result.status} accepted=${result.accepted} rejected=${result.rejected}',
    );
    setState(() => _lastFlush = result);
  }

  @override
  Widget build(BuildContext context) {
    final texts = _Texts.current;
    final status = Feralin.getStatus();
    final consent = status.consent;
    final last = _lastFlush;
    return Scaffold(
      appBar: AppBar(title: Text(texts.title)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              '${texts.consent}: ${consent == null ? texts.pending : consent.analytics}\n'
              '${texts.advertising}: ${consent?.advertising ?? texts.pending}\n'
              '${texts.queued}: ${status.queued}\n'
              '${texts.lastSend}: ${last == null ? texts.notSent : 'HTTP ${last.status}, ${texts.accepted} ${last.accepted}, ${texts.rejected} ${last.rejected}'}',
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => _decide(const Consent(analytics: true)),
              child: Text(texts.grant),
            ),
            FilledButton(
              onPressed: () =>
                  _decide(const Consent(analytics: true, advertising: true)),
              child: Text(texts.grantAd),
            ),
            OutlinedButton(
              onPressed: () => _decide(const Consent(analytics: false)),
              child: Text(texts.deny),
            ),
            OutlinedButton(onPressed: _track, child: Text(texts.track)),
            OutlinedButton(onPressed: _flush, child: Text(texts.flush)),
          ],
        ),
      ),
    );
  }
}
