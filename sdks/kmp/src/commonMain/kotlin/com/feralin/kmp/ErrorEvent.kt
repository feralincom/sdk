package com.feralin.kmp

import kotlin.random.Random

/** Hata olayı adı (X4); ayrılmış sistem olayıdır. */
const val ERROR_EVENT_NAME: String = "fr_error"

/**
 * `fr_error` gövdesi (Android `ErrorEvent.kt` ile aynı alanlar ve temizlik): hata sınıfı adı, temizlenmiş kısa mesaj, normalize edilmiş
 * çerçevelerin özeti olan parmak izi ve en üst çerçeve. Ham yığın izi, dosya adı, satır numarası ve kullanıcı verisi GİTMEZ.
 *
 * Ortak kodda SHA-256 olmadığı için parmak izi Web, React Native ve Flutter SDK'larındaki gibi FNV-1a 64'tür (16 küçük harf onaltılı;
 * toplayıcı 16-64 karakter kabul eder). Çerçeveler `stackTraceToString()` çıktısındaki JVM biçimli `at paket.Sınıf.yöntem(...)`
 * satırlarından okunur; Kotlin/Native (iOS) yığın biçimi okunmaz, orada parmak izi rakamsız mesajdan türer. Sembolleştirme konumları
 * (`frames`) gönderilmez.
 */
internal object ErrorEvents {
    const val ORIGIN_HANDLED = "handled"
    const val ORIGIN_MANUAL = "manual"
    const val ORIGIN_UNCAUGHT = "uncaught_exception"
    const val MAX_MESSAGE = 200
    const val MAX_TYPE = 64
    const val MAX_FRAME = 160
    private const val FINGERPRINT_FRAMES = 5

    // Çerçeve sistemi: bunlar parmak izine girmez (uygulama çerçevesi varsa); hepsi sistemse tüm çerçeveler kullanılır.
    private val FRAMEWORK_PREFIXES = listOf("java.", "javax.", "android.", "androidx.", "kotlin.", "kotlinx.", "dalvik.", "libcore.", "sun.", "com.android.internal.")
    private val SYNTHETIC_SUFFIX = Regex("""[$][$]ExternalSyntheticLambda\d*|[$]\d+|[$][$]Lambda.*""")
    // `at [modül/]paket.Sınıf.yöntem(Dosya.kt:12)`; JVM 9+ modül öneki (`java.base/`, `app//`) atılır.
    private val JVM_FRAME = Regex("""^\s*at\s+([^\s(]+)\(""")

    private val URL = Regex("""\b[a-z][a-z0-9+.-]*://[^\s"'<>]+""", RegexOption.IGNORE_CASE)
    private val EMAIL = Regex("""[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}""")
    private val UUID = Regex("""\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b""", RegexOption.IGNORE_CASE)
    private val TOKEN = Regex("""\b[A-Za-z0-9_\-+/=]{24,}\b""")
    private val NUMBER = Regex("""\+?\d[\d\s\-().]{5,}\d""")
    private val WHITESPACE = Regex("""\s+""")
    private val DIGITS = Regex("""\d+""")

    /** Mesajdan URL, e-posta, UUID, uzun belirteç ve uzun sayıları çıkarır (sıra toplayıcıyla aynı); 200 karaktere kırpar. */
    fun scrub(message: String): String {
        var text = URL.replace(message, "[url]")
        text = EMAIL.replace(text, "[email]")
        text = UUID.replace(text, "[id]")
        text = TOKEN.replace(text) { if (it.value.any(Char::isDigit)) "[token]" else it.value }
        text = NUMBER.replace(text) { match -> if (match.value.count(Char::isDigit) >= 7) "[num]" else match.value }
        return truncate(WHITESPACE.replace(text.trim(), " "), MAX_MESSAGE)
    }

    /** Vekil çifti ortadan bölünmez: toplayıcı kod noktası sayar, yarım karakter bozuk UTF-8 olurdu. */
    private fun truncate(text: String, max: Int): String {
        if (text.length <= max) return text
        val end = if (text[max - 1].isHighSurrogate()) max - 1 else max
        return text.substring(0, end)
    }

    /** Tek çerçeve: `sınıf.yöntem`; derleyicinin ürettiği lambda ve anonim sınıf ekleri atılır. Dosya ve satır yoktur. */
    fun frame(qualified: String): String {
        val name = qualified.substringAfterLast('/')
        val dot = name.lastIndexOf('.')
        if (dot <= 0) return name
        return SYNTHETIC_SUFFIX.replace(name.substring(0, dot), "") + "." + name.substring(dot + 1)
    }

    /** Yalnız en dış hatanın çerçeveleri (`Caused by:` ve `Suppressed:` bölümleri dahil edilmez); uygulama çerçevesi varsa yalnız onlar. */
    fun frames(stackTrace: String): List<String> {
        val all = ArrayList<String>()
        for (line in stackTrace.lineSequence()) {
            val trimmed = line.trimStart()
            if (trimmed.startsWith("Caused by:") || trimmed.startsWith("Suppressed:")) break
            val match = JVM_FRAME.find(line) ?: continue
            all.add(frame(match.groupValues[1]))
        }
        val app = all.filter { label -> FRAMEWORK_PREFIXES.none { label.startsWith(it) } }
        return app.ifEmpty { all }
    }

    /** FNV-1a 64 (UTF-8 baytları üzerinde), 16 küçük harf onaltılı. */
    fun fnv1a64(text: String): String {
        var value = 0xCBF29CE484222325uL
        for (byte in text.encodeToByteArray()) {
            value = (value xor byte.toUByte().toULong()) * 0x100000001B3uL
        }
        return value.toString(16).padStart(16, '0')
    }

    fun fingerprint(type: String, frames: List<String>, message: String): String {
        val basis = if (frames.isNotEmpty()) frames.take(FINGERPRINT_FRAMES).joinToString("|") else DIGITS.replace(message, "#")
        return fnv1a64("$type|$basis")
    }

    fun typeName(error: Throwable): String = (error::class.simpleName ?: "").take(MAX_TYPE).ifEmpty { "Error" }

    /** Hata gövdesi; sözleşme alanlarının tamamı. [appVersion] 1-32 karakterse eklenir. */
    fun properties(error: Throwable, origin: String, fatal: Boolean, appVersion: String?): Map<String, Any?> {
        val type = typeName(error)
        val message = scrub(error.message ?: "")
        val frames = frames(error.stackTraceToString())
        val out = LinkedHashMap<String, Any?>()
        out["error_type"] = type
        if (message.isNotEmpty()) out["message"] = message
        out["fingerprint"] = fingerprint(type, frames, message)
        frames.firstOrNull()?.let { out["top_frame"] = truncate(it, MAX_FRAME) }
        out["frame_count"] = frames.size.coerceAtMost(1000)
        if (!appVersion.isNullOrEmpty() && appVersion.length <= 32) out["app_version"] = appVersion
        out["handled"] = origin == ORIGIN_HANDLED || origin == ORIGIN_MANUAL
        out["fatal"] = fatal
        out["origin"] = origin
        return out
    }
}

/**
 * Hata fırtınası sınırı: istemci başına en çok [maxEvents] olay, aynı parmak izi için en çok [maxPerFingerprint]. Örnekleme
 * [sampleRate] ile (0..1); rastgele kaynak test için verilebilir.
 */
internal class ErrorLimiter(
    private val sampleRate: Double = 1.0,
    private val maxEvents: Int = 20,
    private val maxPerFingerprint: Int = 3,
    private val random: () -> Double = { Random.nextDouble() },
) {
    private val lock = createLock()
    private var total = 0
    private val perFingerprint = HashMap<String, Int>()

    fun allow(fingerprint: String): Boolean = lock.withLock {
        if (total >= maxEvents) return@withLock false
        if (sampleRate < 1.0 && random() >= sampleRate) return@withLock false
        val seen = perFingerprint[fingerprint] ?: 0
        if (seen >= maxPerFingerprint) return@withLock false
        perFingerprint[fingerprint] = seen + 1
        total++
        true
    }
}
