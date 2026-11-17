package com.feralin.sdk;

/** 5xx, 429 veya ağ hatası: olaylar kuyrukta tutuldu, aynı Idempotency-Key ile yeniden denenecek. */
public final class TemporaryException extends DeliveryException {
    private static final long serialVersionUID = 1L;

    /**
     * @param message hata iletisi
     * @param status HTTP durum kodu, ağ hatasında 0
     */
    public TemporaryException(String message, int status) {
        super(message, status, "");
    }

    /**
     * @param message hata iletisi
     * @param cause kök neden
     */
    public TemporaryException(String message, Throwable cause) {
        super(message, 0, cause);
    }
}
