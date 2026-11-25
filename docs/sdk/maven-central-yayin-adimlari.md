# Maven Central yayını: adımlar ve durum

Kapsam: `com.feralin:android` (`sdks/android`), `com.feralin:java` ve `com.feralin:feralin-spring-boot-starter` (`sdks/java`). KMP (`sdks/kmp`) bu yayına girmez: iOS parçası Mac olmadan derlenmiyor, kapıda engelli. Düzenek npm ile aynıdır (`docs/sdk/npm-yayin-adimlari.md`): tek komut, gizli giriş, hazırlık, kuru koşu, `YAYINLA` onayı, yayın, depodan geri okuma, günlük. Maven Central'da yayımlanan sürüm silinemez ve değiştirilemez.

## Durum (19 Kasım 2026)

- **Yayında (19 Kasım 2026):** `com.feralin:android:0.1.0`, `com.feralin:java:0.1.0`, `com.feralin:feralin-spring-boot-starter:0.1.0`. Central Portal hesabı GitHub ile açıldı; `com.feralin` feralin.com DNS TXT kaydıyla doğrulandı; imza anahtarı `BA912389B7C92BA9A702E74265D5A3DAF29F897F` (Gpg4win, bu makinede; herkese açık kısmı keyserver.ubuntu.com ve keys.openpgp.org'da). Üç paketin repo1 geri okuması yerel paketle aynı (sha256). Günlük `out/sdk-publish/maven-2026-11-19T15-15-05-135Z.json`.
- Paketler Central zorunluluklarını karşılar: POM'da ad, açıklama, adres, MIT lisansı, geliştirici (`Feralin <noreply@feralin.com>`), SCM (`github.com/feralincom/sdk`); her paket için ana dosya, `-sources.jar`, `-javadoc.jar`, `.md5`, `.sha1`. Android paketine kaynak ve javadoc jar'ı 19 Kasım 2026'da eklendi.
- Betik: `scripts/sdk-publish/maven-publish.mjs` (bağdaştırıcı), `scripts/sdk-publish/maven-yayinla.ps1` (tek komut). Kuru koşu dosyaları yalnız o koşuya özel, parolasız, bir günlük geçici bir GPG anahtarıyla imzalar ve doğrular; Central Portal paket arşivini (`out/maven-central/*-bundle.zip`) üretir; hiçbir yere yüklemez.

## Site sahibinin yapacakları

1. **Hesap:** <https://central.sonatype.com> → Sign In (GitHub ya da e-posta). Feralin'e ait bir hesap önerilir.
2. **Ad alanı:** Portal → Namespaces → Add Namespace → `com.feralin`. Portal bir doğrulama anahtarı verir; `feralin.com` alanına bu değerle bir **DNS TXT** kaydı ekleyin (kayıt adı alanın kendisi, `@`). Portal'da **Verify Namespace**. Doğrulama genellikle dakikalar sürer; kayıt yayımdan sonra kaldırılabilir.
3. **GPG anahtarı** (bir kez; bu makinede Gpg4win kurulu: `C:\Program Files\GnuPG\bin\gpg.exe`):

   ```powershell
   gpg --quick-gen-key "Feralin <noreply@feralin.com>" ed25519 sign 2y
   gpg --list-secret-keys --keyid-format long
   gpg --keyserver keyserver.ubuntu.com --send-keys ANAHTAR_KIMLIGI
   ```

   İlk komut parola sorar; parolayı güvenli yerde saklayın. Central imzayı herkese açık anahtar sunucusundan doğrular; üçüncü komut bu yüzden gerekir (anahtar sunucusu `keyserver.ubuntu.com`, `keys.openpgp.org` ya da `pgp.mit.edu`). `ANAHTAR_KIMLIGI` ikinci komutun `sec ed25519/` satırındaki 16 karakterlik değerdir.
4. **Kullanıcı anahtarı:** Portal → sağ üst → View Account → **Generate User Token**. Ekranda bir kullanıcı adı ve bir parola gösterilir (bir kez). Betik ikisini `kullanıcı:parola` biçiminde ister.
5. **Tek komut** (proje kökünden, temiz çalışma ağacında):

   ```powershell
   .\scripts\sdk-publish\maven-yayinla.ps1 -Onaylayan "Ad Soyad" -GpgAnahtari ANAHTAR_KIMLIGI
   ```

   Sıra: gpg ve gizli anahtar denetimi → kullanıcı anahtarı ve GPG parolası (gizli) → hazırlık (yaklaşık 6 dakika: paketleme, Android ve Java testleri, güvenlik taraması) → kuru koşu → `YAYINLA` → her paket için imza, yükleme (`publishingType=AUTOMATIC`), Portal doğrulaması (birkaç dakika) → `repo1.maven.org` geri okuması (eşitleme 30 dakikaya kadar sürebilir; süre dolarsa aynı komut kaldığı yerden sürer). `com.feralin:java` starter'dan önce yayınlanır.
6. Yayından sonra kullanıcı anahtarını Portal'dan iptal edebilirsiniz.

## Kuru koşu (anahtarsız)

```bash
export ANDROID_HOME="$LOCALAPPDATA/Android/Sdk"
node scripts/sdk-dry-run/run.mjs --sdk android,java --run-tests
node scripts/sdk-dry-run/sca.mjs --sdk android,java
node scripts/sdk-publish/maven-publish.mjs --owner-approved "Ad Soyad" --sdk android,java
```

## Yayından sonra

- Geri okuma: `https://repo1.maven.org/maven2/com/feralin/android/0.1.0/` ve arama <https://central.sonatype.com/namespace/com.feralin>.
- `sdks/capabilities.yaml` üç pakette `registry.status: PUBLISHED`, `chain.registry: PASS`; `node scripts/sdk-dry-run/matrix.mjs --write` ve `docs.mjs --write`.
- React Native paketi Android çekirdeğini bugün npm paketinin içinde (`android/maven-repo`) taşır; Central yayınından sonra `sdks/react-native/android/build.gradle` doğrudan `mavenCentral()` kullanabilir (ayrı iş).

## Geri alma

Yayımlanan sürüm silinemez. Hatalı sürüm yeni yama sürümüyle düzeltilir (`0.1.1`); CHANGELOG'da eski sürüm "kullanmayın" diye yazılır.
