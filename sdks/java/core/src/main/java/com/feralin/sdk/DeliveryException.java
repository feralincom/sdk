package com.feralin.sdk;

/** Toplayıcıya gönderim hatası; durum kodu 0 ise ağ hatasıdır. flush fırlatmaz, {@link FlushResult#error()} döner. */
public class DeliveryException extends FeralinException {
    private static final long serialVersionUID = 1L;

    private final int status;
    private final String detail;

    /**
     * @param message hata iletisi
     * @param status HTTP durum kodu, ağ hatasında 0
     * @param detail kısa problem özeti, yoksa boş
     */
    public DeliveryException(String message, int status, String detail) {
        super(message);
        this.status = status;
        this.detail = detail == null ? "" : detail;
    }

    /**
     * @param message hata iletisi
     * @param status HTTP durum kodu, ağ hatasında 0
     * @param cause kök neden
     */
    public DeliveryException(String message, int status, Throwable cause) {
        super(message, cause);
        this.status = status;
        this.detail = "";
    }

    /** @return HTTP durum kodu, ağ hatasında 0 */
    public int status() {
        return status;
    }

    /** @return kısa problem özeti, yoksa boş */
    public String detail() {
        return detail;
    }
}
