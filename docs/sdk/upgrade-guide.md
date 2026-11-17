# SDK yükseltme rehberi ve eski sürüme dönüş (SDK-R09)

Durum (13 Kasım 2026): hiçbir SDK registry'de yayınlı değil (`BLOCKED_EXTERNAL`). Aşağıdaki geçişler yayınlanmamış yapılar arasındadır; kurallar ilk yayından itibaren aynen geçerlidir. Sürüm kaynağı `sdks/capabilities.yaml`, sürüm notları her paketin `CHANGELOG.md` dosyası, yayın kontrol listesi `docs/sdk/release-checklist.md` §5.

## 1. Genel kurallar

- **SemVer.** Genel API kırılması major sürüm ister. `0.x` sürümlerinde minor artış kırıcı olabilir; kırıcı her değişiklik `CHANGELOG.md` içinde **davranış değişikliği** diye yazılır.
- **Kalıcı biçim değişikliği** (disk kuyruğu, işaret dosyası, anahtar saklama) API değişmese de bu rehbere SDK satırı ister: yükseltme yolu, dönüş yolu, dönüşte kayıp ve çift gönderim davranışı. Davranış testle sabitlenir ya da burada açıkça belgelenir.
- **Olay kimliği değişmez.** Kuyruktaki olay her yeniden denemede aynı `event_id` ile gider. Aynı olay kümesi aynı `Idempotency-Key` üretir; toplayıcı aynı anahtarla gelen batch için ikinci outbox satırı yazmaz (`services/collect`, `collect_idempotency`). Yükseltme ve dönüş testleri bu iki kuralı denetler.
- **Desteklenen dönüş yönü:** aynı kalıcı biçimi okuyan sürümler arasında dönüş kayıpsızdır. Biçimi okuyamayan eski sürüme dönüş desteklenmez; zorunluysa kayıp aşağıdaki tablolarda yazılı olduğu kadardır, çift gönderim yoktur.
- **Tercih edilen geri alma:** sorunlu sürümü yayın hattında `withdraw` (deprecate/yank, `docs/sdk/trusted-publishing.md` §4) ile önermeyi durdurup aynı kalıcı biçimle bir düzeltme sürümü (`0.2.x`) çıkarmak. Uygulama geri alınacaksa uygulamanın önceki sürümü SDK'nın kalıcı biçimi okuyan sürümüyle yeniden derlenir; SDK biçimin gerisine indirilmez.

## 2. Şifreli kalıcı kuyruk (`enc1:`): Flutter, Android, Unity

Üç SDK aynı satır biçimini kullanır: `enc1:` + hex(iv ‖ şifreli metin ‖ etiket), AES-256-GCM, ilişkilendirilmiş veri olay kimliği (`sdks/android/.../EncryptedEventStore.kt`, `sdks/flutter/lib/src/core/event_store.dart`, `sdks/unity/Runtime/Core/Persistence.cs`). Anahtar cihazdadır (Android Keystore, iOS Keychain; Unity'de Keystore, Keychain ya da DPAPI ile sarılmış dosya, açıkça seçilirse yalnız dosya izniyle korunan `local_file`); yedekle başka cihaza taşınmaz. Olay kimliği, anonim kimlik ve işaretler (ilk açılış, referrer okundu) şifresizdir.

| SDK | Geçiş | Yükseltme (eski → yeni) | Dönüş (yeni → eski) | Kanıt |
|---|---|---|---|---|
| Flutter `feralin_flutter` | 0.1.0 → 0.2.0 | 0.1.0 dosyası (`feralin_sdk/queue.jsonl`, satır başına düz olay JSON'u) ilk açılışta okunur, her olay aynı kimlik ve sırayla bir kez yüklenir ve dosya şifreli olarak yeniden yazılır. Kesilen ilk gönderim yeniden başlatmada aynı `Idempotency-Key` ile bir kez kabul edilir. Anahtar alınamazsa olay bellekte kalır, düz metne düşülmez. | **Desteklenmez.** 0.1.0, `{"event_id","enc"}` satırını olay gövdesi sanar ve gönderir; gövdede `event_name` yoktur, toplayıcı o olayı tek tek reddeder (UTP şeması), aynı batch'teki düz olaylar kabul edilir. Bekleyen şifreli olaylar **kaybolur**, çift gönderim olmaz. 0.1.0 çevrimdışıyken şifreli satırları olduğu gibi bırakır; o arada yeniden 0.2.0'a çıkılırsa hepsi bir kez okunur. | `sdks/flutter/test/upgrade_rollback_test.dart`, `encrypted_store_test.dart` |
| Android `com.feralin:android` | 0.1.0 içinde (11 Kasım 2026, sürüm numarası değişmedi) şifresiz yapı → şifreli yapı | Şifresiz SQLite satırları ilk okumada şifreli yazılır; olaylar kaybolmaz, 500 sonrası yeniden başlatmada aynı kimlik ve `Idempotency-Key` ile bir kez kabul edilir; ilk açılış işareti korunur, ikinci `app_first_open` üretilmez. Aynı Keystore anahtarını kullanan şifreli yapılar arasında dönüş kayıpsızdır. | **Desteklenmez.** Şifresiz yapı `enc1:` satırını açamaz. Reklam izni açık değilse açılışta atıf ayıklaması satırı ayrıştıramaz ve **atar** (hiç gönderilmez); reklam izni açıksa satır batch'e girer, gövde geçersiz JSON olur, toplayıcı 400 döner ve motor **bütün batch'i** kalıcı ret olarak siler (aynı batch'teki düz olaylar dahil). Her iki durumda çift gönderim yoktur; silinen satır yeniden yükseltmede geri gelmez. | `sdks/android/feralin/src/test/.../QueueUpgradeRollbackTest.kt`, `EncryptedEventStoreTest.kt` |
| Unity `com.feralin.unity` | 0.1.0 → 0.2.0 | 0.1.0 kuyruğu yalnız bellekteydi, taşınacak disk verisi yoktur. Güncelleme sürecinde 0.1.0'ın gönderilmemiş bellek olayları kaybolur (0.1.0 davranışı); 0.2.0 boş kuyrukla başlar, olay uydurmaz. | 0.1.0 diski okumaz ve silmez: 0.2.0'ın bekleyen şifreli olayları diskte kalır, 0.1.0 yalnız kendi olaylarını gönderir. Yeniden 0.2.0'a çıkınca diskteki olaylar aynı kimlikle bir kez gider (eski olay atma ve kuyruk sınırı kuralları uygulanır). Kayıp yok, çift gönderim yok. | `sdks/unity/Tests~/Feralin.Unity.Core.Tests/PersistenceTests.cs` (`UpgradeFromMemoryOnlyBuild…`, `RollbackToMemoryOnlyBuild…`, `OfflineEventsSurviveRestart…`) |

Ortak notlar:

- **Anahtar kaybı** (uygulama verisi silindi, Keystore/Keychain sıfırlandı, veri başka cihaza yedekten döndü): şifreli satırlar açılamaz ve atılır; gönderilemeyecek veri birikmez. Bu bir kayıptır, çift gönderim değildir.
- **İzin:** analitik izni geri çekilirse kuyruk ve disk silinir; izin kararı yokken disk okunmaz ve silinmez (Unity). Yükseltme izin kararını değiştirmez; uygulama her açılışta gerçek izin değerini vermelidir.
- **Unity ilk açılış:** 0.1.0 kalıcı işaret tutmuyordu. 0.2.0'da `StartAttribution` çağrılırsa ilk açılış işareti olmadığı için mevcut kurulum için de bir kez `app_first_open` üretilir. Yükseltilen uygulamalarda kurulum sayımı bunu hesaba katmalıdır.
- **Unity gelir olayı:** 0.2.0'da `TrackIapPurchase` `iap_purchase` değil `feralin_purchase` üretir ve `transactionId` ister (davranış değişikliği, `sdks/unity/CHANGELOG.md`). Panel ve sorgularda eski olay adı yükseltilen istemcilerden gelmez.

## 3. Yeni kalıcı biçim değişikliğinde

1. Yeni sürüm eski biçimi okur ve yeni biçime bir kez çevirir; olay kimliği ve sırası korunur.
2. Okunamayan satır sessizce birikmez: ya çevrilir ya atılır, atma `CHANGELOG.md` ve bu rehberde yazılır.
3. Eski sürümün yeni biçimi nasıl gördüğü (atar mı, gönderir mi, dokunmaz mı) eski sürümün koduna bakılarak bu tabloya yazılır; mümkünse testle sabitlenir.
4. Yükseltme testi: eski biçimde biriken kuyruk → yeni sürüm → kesilen gönderim → yeniden başlatma → her olay bir kez kabul, aynı `Idempotency-Key`.
5. `docs/sdk/release-checklist.md` §5 maddesi bu satır yazılmadan işaretlenmez.
