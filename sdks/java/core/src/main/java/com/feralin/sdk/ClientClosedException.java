package com.feralin.sdk;

/** Kapanıştan sonra track veya flush çağrıldı. */
public final class ClientClosedException extends FeralinException {
    private static final long serialVersionUID = 1L;

    /** @param message hata iletisi */
    public ClientClosedException(String message) {
        super(message);
    }
}
