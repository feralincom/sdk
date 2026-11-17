package com.feralin.sdk;

/** Geçersiz proje anahtarı, toplayıcı adresi veya seçenek. */
public final class ConfigurationException extends FeralinException {
    private static final long serialVersionUID = 1L;

    /** @param message hata iletisi; anahtar değeri içermez */
    public ConfigurationException(String message) {
        super(message);
    }
}
