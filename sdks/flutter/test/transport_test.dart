import 'dart:convert';
import 'dart:io';

import 'package:feralin_flutter/src/core/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Yerel gerçek soket üzerinde HTTP davranışı.
void main() {
  late HttpServer server;
  late String base;
  String receivedBody = '';
  HttpHeaders? receivedHeaders;
  var targetHits = 0;

  setUp(() async {
    targetHits = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((request) async {
      final body = await utf8.decodeStream(request);
      switch (request.uri.path) {
        case '/ok':
          receivedBody = body;
          receivedHeaders = request.headers;
          request.response.statusCode = 202;
          request.response.write('{"accepted":1}');
        case '/limited':
          request.response.statusCode = 429;
          request.response.headers.set('Retry-After', '7');
        case '/redirect':
          request.response.statusCode = 302;
          request.response.headers.set('Location', '$base/target');
        default:
          targetHits++;
          request.response.statusCode = 204;
      }
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  test('gövde ve başlıklar gider, User-Agent yalnız SDK', () async {
    final response = await IoHttpTransport().post('$base/ok', {
      'x-feralin-project-key': 'pk_test_1',
      'user-agent': 'feralin-flutter/1',
      'content-type': 'application/json',
    }, '{"türkçe":"ığüş"}');
    expect(response!.status, 202);
    expect(response.body, '{"accepted":1}');
    expect(receivedBody, '{"türkçe":"ığüş"}');
    expect(receivedHeaders!.value('x-feralin-project-key'), 'pk_test_1');
    expect(receivedHeaders!.value('user-agent'), 'feralin-flutter/1');
    expect(response.retryAfterSeconds, isNull);
  });

  test('Retry-After okunur', () async {
    final response = await IoHttpTransport().post('$base/limited', {}, '{}');
    expect(response!.status, 429);
    expect(response.retryAfterSeconds, 7);
  });

  test('yönlendirme izlenmez', () async {
    final response = await IoHttpTransport().post('$base/redirect', {}, '{}');
    expect(response!.status, 302);
    expect(targetHits, 0);
  });

  test('kapalı port null döner, fırlatmaz', () async {
    final port = server.port;
    await server.close(force: true);
    final response = await IoHttpTransport(
      connectTimeout: const Duration(milliseconds: 500),
    ).post('http://127.0.0.1:$port/ok', {}, '{}');
    expect(response, isNull);
  });

  test('geçersiz adres null döner, fırlatmaz', () async {
    final response = await IoHttpTransport().post('http://[bozuk', {}, '{}');
    expect(response, isNull);
  });
}
