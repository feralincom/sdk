package com.feralin.sdk;

/** event_name, properties veya kimlik alanı UTP v1 kurallarına uymuyor. */
public final class InvalidEventException extends FeralinException {
    private static final long serialVersionUID = 1L;

    /** @param message hata iletisi */
    public InvalidEventException(String message) {
        super(message);
    }
}
