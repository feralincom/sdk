package com.feralin.sdk;

/** Bütün SDK hatalarının tabanı. Denetlenmez: analitik çağrısı uygulama akışını try/catch'e zorlamaz. */
public class FeralinException extends RuntimeException {
    private static final long serialVersionUID = 1L;

    /** @param message hata iletisi */
    public FeralinException(String message) {
        super(message);
    }

    /**
     * @param message hata iletisi
     * @param cause kök neden
     */
    public FeralinException(String message, Throwable cause) {
        super(message, cause);
    }
}
