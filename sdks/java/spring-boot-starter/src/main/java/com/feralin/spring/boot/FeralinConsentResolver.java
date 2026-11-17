package com.feralin.spring.boot;

import com.feralin.sdk.Consent;
import jakarta.servlet.http.HttpServletRequest;

/**
 * Her HTTP isteği için izin kararını verir. İzin müşteri uygulamasına aittir: kendi izin çerezinizi veya kullanıcı
 * kaydınızı okuyan bir bean tanımlayın. Tanımlanmazsa {@code feralin.consent.*} değerleri kullanılır, varsayılanı
 * hiçbir izin yoktur.
 */
@FunctionalInterface
public interface FeralinConsentResolver {

    /**
     * @param request geçerli HTTP isteği
     * @return bu isteğin izni
     */
    Consent resolve(HttpServletRequest request);
}
