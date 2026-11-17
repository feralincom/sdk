/// Kuyruktaki olay gövdesini diskte şifreli tutan sınır. Biçim Android çekirdeğiyle (`EncryptedEventStore`) aynıdır:
/// `enc1:` + onaltılı(IV ‖ şifreli metin ‖ GCM etiketi), AES-256-GCM, ilişkilendirilmiş veri olay kimliği. Anahtar yerel tarafta
/// kalır (Android Keystore, iOS Keychain) ve Dart'a hiç geçmez.
abstract class QueueCipher {
  /// Şifreli satırın öneki; bu önek yoksa satır eski sürümün düz metnidir.
  static const String prefix = 'enc1:';

  /// Şifreler; anahtar alınamazsa ya da yerel taraf yoksa `null` (çağıran düz metne DÜŞMEZ, olayı bellekte tutar).
  Future<String?> encrypt(String plain, String aad);

  /// Açılamazsa (bozuk, kurcalanmış, anahtar kayıp) `null`. Asla fırlatmaz.
  Future<String?> decrypt(String stored, String aad);
}
