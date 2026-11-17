package com.feralin.sdk;

/** 4xx (429 hariç): batch kalıcı olarak reddedildi, olaylar kuyruktan atıldı. */
public final class RejectedException extends DeliveryException {
    private static final long serialVersionUID = 1L;

    /**
     * @param message hata iletisi
     * @param status HTTP durum kodu
     * @param detail kısa problem özeti
     */
    public RejectedException(String message, int status, String detail) {
        super(message, status, detail);
    }
}
