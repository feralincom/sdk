# Packagist yayını: adımlar ve durum

Kapsam: `feralin/feralin-php` (`sdks/php`), `feralin/feralin-laravel` (`sdks/php-laravel`), `feralin/feralin-symfony` (`sdks/php-symfony`). Packagist paket dosyası barındırmaz; GitHub deposunu okur ve sürümü **Git etiketinden** alır. Bir depo tek paket sayılır ve `composer.json` depo kökünde aranır (<https://packagist.org/about>). Tekli depo `feralincom/sdk` bu yüzden doğrudan gönderilemez; her paket kendi deposuna bölünür.

## Durum (19 Kasım 2026)

- **Yayında (19 Kasım 2026):** `feralin/feralin-php`, `feralin/feralin-laravel`, `feralin/feralin-symfony` 0.1.0. Packagist hesabı site sahibinin GitHub hesabıyla açıldı; üç depo gönderildi. Geri okuma: `repo.packagist.org/p2/feralin/<paket>.json` 0.1.0, kaynak etiketli GitHub zipball. Otomatik güncelleme kancası kurulmadı; yeni sürümde paket sayfasında **Update** ya da 4. adım.
- Betik: `scripts/sdk-publish/packagist-split.mjs`. Kaynak, sır taramasından geçmiş herkese açık ağaçtır (`out/public-repo`). Betik yerel geliştirme için konan `../php` yol deposunu (`repositories`) `composer.json` dosyasından çıkarır, `tests/` dizinini Composer arşivinden dışlayan `.gitattributes` ekler ve zorunlu alanları denetler. Yerel deneme (`--push` olmadan) geçti: üç paket `HAZIR`.
- Depolar site sahibinin onayıyla açıldı ve gönderildi (19 Kasım 2026): `feralincom/feralin-php` (`4f77d27`), `feralincom/feralin-laravel` (`2708833`), `feralincom/feralin-symfony` (`167ad1c`); üçünde `v0.1.0` etiketi var. Packagist'e gönderim (aşağıda 2. ve 3. adım) site sahibini bekliyor.

## Adımlar

1. **Depolar ve etiketler** (onaydan sonra; GitHub CLI `feralincom` üzerinde yazma yetkili hesapla oturum açmış olmalı):

   ```bash
   node scripts/sdk-publish/export-public-repo.mjs --check
   node scripts/sdk-publish/packagist-split.mjs --push
   ```

   Betik depoyu yoksa açar, `main` dalına gönderir ve `v0.1.0` etiketini atar. Etiket zaten varsa o depoya dokunmaz; etiket taşınmaz.
2. **Packagist hesabı (site sahibi):** <https://packagist.org/login> → **GitHub ile giriş**. GitHub ile girmek, depo değişince paketin kendiliğinden güncellenmesi için gereken bağlantıyı da kurar.
3. **Paketleri gönderin:** <https://packagist.org/packages/submit> adresine sırayla şunları yazıp **Check** → **Submit**:
   - `https://github.com/feralincom/feralin-php` (önce bu: öteki ikisi ona bağımlıdır)
   - `https://github.com/feralincom/feralin-laravel`
   - `https://github.com/feralincom/feralin-symfony`
4. **Otomatik güncelleme:** Packagist → Profile → "Your packages": paketin yanında "not auto-updated" uyarısı varsa GitHub hesabını bağlayın (Profile → Settings → Connect GitHub) ya da depoya Packagist webhook'u ekleyin (<https://packagist.org/about#how-to-update-packages>).
5. **Doğrulama:** `composer require feralin/feralin-php:^0.1` boş bir projede kurulmalı; `https://repo.packagist.org/p2/feralin/feralin-php.json` içinde `0.1.0` görünmeli.

## Sonraki sürümler

Sürüm `composer.json` içindeki `version` alanından alınır ve etiket `v<sürüm>` olur. Sürüm yükseltilmeden betik var olan etiketi değiştirmez. Yayımlanmış etiket taşınmaz; hatalı sürüm yeni yama sürümüyle düzeltilir.
