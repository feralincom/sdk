import 'dart:async';
import 'dart:convert';
import 'dart:io';

class TransportResponse {
  const TransportResponse(this.status, this.body, this.retryAfterSeconds);

  final int status;
  final String body;
  final int? retryAfterSeconds;
}

abstract class Transport {
  /// Ağ hatasında `null` döner; asla fırlatmaz.
  Future<TransportResponse?> post(
    String url,
    Map<String, String> headers,
    String body,
  );
}

/// `dart:io` üzerinde bağımlılıksız HTTP. Yönlendirme izlenmez: anahtar başlığı başka ana makineye taşınmamalıdır.
class IoHttpTransport implements Transport {
  IoHttpTransport({
    this.connectTimeout = const Duration(seconds: 10),
    this.requestTimeout = const Duration(seconds: 25),
  });

  static const int _maxResponseBytes = 64 * 1024;

  final Duration connectTimeout;
  final Duration requestTimeout;

  @override
  Future<TransportResponse?> post(
    String url,
    Map<String, String> headers,
    String body,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      // Dart'ın varsayılan User-Agent'ı yerine yalnız SDK adı/sürümü başlıktan gider.
      ..userAgent = null;
    try {
      return await _send(client, url, headers, body).timeout(requestTimeout);
    } on SocketException {
      return null;
    } on HttpException {
      return null;
    } on TlsException {
      return null;
    } on TimeoutException {
      return null;
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<TransportResponse> _send(
    HttpClient client,
    String url,
    Map<String, String> headers,
    String body,
  ) async {
    final request = await client.postUrl(Uri.parse(url));
    request.followRedirects = false;
    headers.forEach(request.headers.set);
    final bytes = utf8.encode(body);
    request.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    final received = <int>[];
    await for (final chunk in response) {
      if (received.length < _maxResponseBytes) received.addAll(chunk);
    }
    final limited = received.length > _maxResponseBytes
        ? received.sublist(0, _maxResponseBytes)
        : received;
    return TransportResponse(
      response.statusCode,
      utf8.decode(limited, allowMalformed: true),
      int.tryParse(response.headers.value('retry-after')?.trim() ?? ''),
    );
  }
}
