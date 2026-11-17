package com.feralin.sdk;

import java.time.Duration;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/** HTTP taşıma katmanı; varsayılanı {@link HttpClientTransport}. Testler ve özel ağ yığınları için değiştirilebilir. */
@FunctionalInterface
public interface Transport {

    /**
     * POST isteği yapar. HTTP hata kodları normal yanıt olarak döner.
     *
     * @param url tam istek adresi
     * @param body istek gövdesi
     * @param headers istek başlıkları; proje anahtarı içerir, loglanmamalı
     * @param timeout bütün istek için süre sınırı
     * @return toplayıcı yanıtı
     * @throws TemporaryException ağ hatası veya zaman aşımında
     */
    Response send(String url, byte[] body, Map<String, String> headers, Duration timeout);

    /** Toplayıcı yanıtı. */
    final class Response {
        private final int status;
        private final byte[] body;
        private final Map<String, String> headers;

        /**
         * @param status HTTP durum kodu
         * @param body yanıt gövdesi veya null
         * @param headers yanıt başlıkları veya null
         */
        public Response(int status, byte[] body, Map<String, String> headers) {
            this.status = status;
            this.body = body == null ? new byte[0] : body.clone();
            this.headers = headers == null ? Collections.emptyMap() : Collections.unmodifiableMap(new LinkedHashMap<>(headers));
        }

        /** @return HTTP durum kodu */
        public int status() {
            return status;
        }

        /** @return yanıt gövdesinin kopyası */
        public byte[] body() {
            return body.clone();
        }

        /**
         * Büyük küçük harf duyarsız başlık okuması.
         *
         * @param name başlık adı
         * @return değer veya null
         */
        public String header(String name) {
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                if (entry.getKey().equalsIgnoreCase(name)) {
                    return entry.getValue();
                }
            }
            return null;
        }
    }
}
