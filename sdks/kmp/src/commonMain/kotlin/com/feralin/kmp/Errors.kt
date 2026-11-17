package com.feralin.kmp

/** Yapılandırma ve doğrulama hataları fırlatılır. Teslim hataları [FlushResult.error] içinde döner; `flush` ağ hatası için fırlatmaz. */
sealed class FeralinException(message: String) : Exception(message) {
    /** Geçersiz proje anahtarı, adres veya seçenek. */
    class Configuration(message: String) : FeralinException(message)

    /** Olay adı, özellik veya kimlik UTP v1 kurallarına uymuyor. */
    class InvalidEvent(message: String) : FeralinException(message)

    /** `close` sonrası `track` veya `flush` çağrıldı. */
    class ClientClosed : FeralinException("istemci kapatıldı")
}

/** Toplayıcıya gönderim hatası. `status` 0 ise ağ hatasıdır. */
sealed class DeliveryError {
    abstract val status: Int

    /** 4xx (429 hariç): batch kalıcı olarak reddedildi, olaylar kuyruktan atıldı. */
    data class Rejected(override val status: Int, val detail: String) : DeliveryError()

    /** 5xx, 429 veya ağ hatası: olaylar kuyrukta, aynı `Idempotency-Key` ile yeniden denenir. */
    data class Temporary(override val status: Int, val message: String) : DeliveryError()
}
