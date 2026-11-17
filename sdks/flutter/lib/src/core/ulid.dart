import 'dart:math';

const String _encoding = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
final Random _random = Random.secure();
int _lastTime = -1;
List<int> _lastRandom = const [];

/// ULID (Crockford base32, 26 karakter): zaman sıralı event_id. Aynı milisaniyede monotonik artar.
String nextUlid(int nowMs) {
  final List<int> rand;
  if (nowMs == _lastTime) {
    rand = List<int>.of(_lastRandom);
    for (var i = rand.length - 1; i >= 0; i--) {
      if (rand[i] < 31) {
        rand[i]++;
        break;
      }
      rand[i] = 0;
    }
  } else {
    rand = List<int>.generate(16, (_) => _random.nextInt(32));
  }
  _lastTime = nowMs;
  _lastRandom = rand;

  final time = List<String>.filled(10, '0');
  var t = nowMs;
  for (var i = 9; i >= 0; i--) {
    time[i] = _encoding[t % 32];
    t = t ~/ 32;
  }
  return time.join() + rand.map((v) => _encoding[v]).join();
}
