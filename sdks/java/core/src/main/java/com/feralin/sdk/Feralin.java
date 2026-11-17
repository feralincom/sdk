package com.feralin.sdk;

import java.util.Map;
import java.util.Optional;

/**
 * Feralin olay yüzeyi. İki uygulaması vardır: uygulama geneli {@link FeralinClient} ve
 * {@link FeralinClient#scoped(Consent)} ile alınan, izni ve kimliği kendine ait görünüm.
 */
public interface Feralin {

    /**
     * Olayı doğrular, UTP v1 biçimine çevirir ve kuyruğa ekler; ağ çağrısı yapmaz.
     *
     * @param eventName snake_case olay adı, en fazla 100 karakter
     * @param properties olay özellikleri veya null; en fazla 100 anahtar
     * @param options olay başına alanlar veya null
     * @return kuyruğa eklenen olay; analytics izni yoksa olay üretilmez ve boş döner
     * @throws InvalidEventException olay UTP v1 kurallarına uymuyorsa
     * @throws ClientClosedException istemci kapatıldıysa
     */
    Optional<UtpEvent> track(String eventName, Map<String, ?> properties, TrackOptions options);

    /**
     * Özelliksiz olay.
     *
     * @param eventName snake_case olay adı
     * @return kuyruğa eklenen olay; analytics izni yoksa boş
     */
    default Optional<UtpEvent> track(String eventName) {
        return track(eventName, null, null);
    }

    /**
     * Özellikli olay.
     *
     * @param eventName snake_case olay adı
     * @param properties olay özellikleri veya null
     * @return kuyruğa eklenen olay; analytics izni yoksa boş
     */
    default Optional<UtpEvent> track(String eventName, Map<String, ?> properties) {
        return track(eventName, properties, null);
    }

    /**
     * Satın alma ya da abonelik beyanı ({@code feralin_purchase}). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı
     * onaylarsa REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; {@code verified} alanı hiçbir zaman gönderilmez.
     *
     * @param revenue {@link Revenue#builder(String, long, String)} ile kurulmuş beyan
     * @param options olay başına alanlar veya null
     * @return kuyruğa eklenen olay; analytics izni yoksa boş
     * @throws InvalidEventException revenue null ise
     */
    default Optional<UtpEvent> trackRevenue(Revenue revenue, TrackOptions options) {
        if (revenue == null) {
            throw new InvalidEventException("revenue null olamaz");
        }
        return track(Revenue.EVENT_NAME, revenue.toProperties(), options);
    }

    /**
     * Seçeneksiz gelir beyanı.
     *
     * @param revenue gelir beyanı
     * @return kuyruğa eklenen olay; analytics izni yoksa boş
     */
    default Optional<UtpEvent> trackRevenue(Revenue revenue) {
        return trackRevenue(revenue, null);
    }

    /**
     * Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: {@code fr_group} olayı, {@code group_id} ve temizlenmiş özellikler.
     * Grup kimliği 1-128 karakter olmalı, {@code @} ve kontrol karakteri içermemelidir; uymazsa olay üretilmez ve boş döner.
     * Kişisel veriye benzeyen anahtar, doğrulama alanı ve sınır dışı değer düşer; toplayıcı yalnız projenin izin listesindeki
     * özellikleri saklar.
     *
     * @param groupId grup kimliği
     * @param traits grup özellikleri veya null
     * @param options olay başına alanlar veya null
     * @return kuyruğa eklenen olay; grup kimliği geçersizse ya da izin yoksa boş
     */
    default Optional<UtpEvent> group(String groupId, Map<String, ?> traits, TrackOptions options) {
        if (!ProfileRules.validGroupId(groupId)) {
            System.getLogger("feralin").log(System.Logger.Level.WARNING, "feralin: fr_group: geçersiz group_id, olay üretilmedi");
            return Optional.empty();
        }
        Map<String, Object> properties = ProfileRules.sanitize(traits);
        properties.put("group_id", groupId);
        return track(ProfileRules.GROUP_EVENT_NAME, properties, options);
    }

    /**
     * Özellikli grup bağlantısı.
     *
     * @param groupId grup kimliği
     * @param traits grup özellikleri veya null
     * @return kuyruğa eklenen olay; geçersizse ya da izin yoksa boş
     */
    default Optional<UtpEvent> group(String groupId, Map<String, ?> traits) {
        return group(groupId, traits, null);
    }

    /**
     * Kullanıcı özelliklerini bildirir: {@code fr_user_properties} olayı. Değer dizge (≤256 karakter, e-posta biçiminde değil),
     * sonlu sayı ya da mantıksal olmalı; kişisel veriye benzeyen anahtar ve doğrulama alanı düşer. Geçerli özellik yoksa olay
     * üretilmez ve boş döner. Toplayıcı yalnız projenin izin listesindeki anahtarları saklar.
     *
     * @param properties kullanıcı özellikleri
     * @param options olay başına alanlar veya null
     * @return kuyruğa eklenen olay; geçerli özellik yoksa ya da izin yoksa boş
     */
    default Optional<UtpEvent> setUserProperties(Map<String, ?> properties, TrackOptions options) {
        Map<String, Object> clean = ProfileRules.sanitize(properties);
        if (clean.isEmpty()) {
            System.getLogger("feralin").log(System.Logger.Level.WARNING, "feralin: fr_user_properties: geçerli özellik yok, olay üretilmedi");
            return Optional.empty();
        }
        return track(ProfileRules.USER_PROPERTIES_EVENT_NAME, clean, options);
    }

    /**
     * Seçeneksiz kullanıcı özellikleri.
     *
     * @param properties kullanıcı özellikleri
     * @return kuyruğa eklenen olay; geçerli özellik yoksa ya da izin yoksa boş
     */
    default Optional<UtpEvent> setUserProperties(Map<String, ?> properties) {
        return setUserProperties(properties, null);
    }

    /**
     * Yakalanan bir hatayı {@code fr_error} olarak bildirir. Ham yığın izi gitmez: hata sınıfı adı, temizlenmiş mesaj, çerçeve
     * özeti olan parmak izi ve sembolleştirme için en çok 5 uygulama çerçevesinin konumu (sınıf, yöntem, satır) gider. 60
     * saniyede en çok 20 olay, aynı parmak izi için en çok 3 olay. Hiçbir durumda fırlatmaz.
     *
     * @param error yakalanan hata
     * @param options olay başına alanlar veya null
     * @return kuyruğa eklenen olay; sınır dolduysa, izin yoksa ya da istemci kapalıysa boş
     */
    Optional<UtpEvent> captureError(Throwable error, TrackOptions options);

    /**
     * Seçeneksiz hata bildirimi.
     *
     * @param error yakalanan hata
     * @return kuyruğa eklenen olay; sınır dolduysa ya da izin yoksa boş
     */
    default Optional<UtpEvent> captureError(Throwable error) {
        return captureError(error, null);
    }

    /**
     * Sonraki olaylar için varsayılan user_id; olay başına verilen değer önceliklidir.
     *
     * @param userId müşteri uygulamasının kimliği (PII olmamalı); null varsayılanı kaldırır
     */
    void identify(String userId);

    /**
     * İzin durumunu günceller. analytics kapanırsa bu yüzeyin bekleyen olayları atılır ve yeni olay üretilmez.
     *
     * @param consent yeni izin durumu
     */
    void setConsent(Consent consent);

    /**
     * Kuyruktaki olayları batch'ler hâlinde gönderir, geri çekilmeyi beklemez. Teslim hatasında fırlatmaz; sonuç
     * {@link FlushResult#error()} içinde döner.
     *
     * @return gönderim özeti
     * @throws ClientClosedException istemci kapatıldıysa
     */
    FlushResult flush();

    /**
     * Paylaşılan kuyruktaki olay sayısı.
     *
     * @return bekleyen olay sayısı
     */
    int queued();

    /**
     * Anlık durum (debug ve sağlık amaçlı). Anahtar döndürülmez.
     *
     * @return durum alanları
     */
    Map<String, Object> status();
}
