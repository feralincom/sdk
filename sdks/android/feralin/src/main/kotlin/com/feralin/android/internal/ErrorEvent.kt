package com.feralin.android.internal

import java.security.MessageDigest

/**
 * `fr_error` sözleşmesi (X4): hata sınıfı adı, temizlenmiş kısa mesaj, normalize edilmiş çerçevelerin özeti olan parmak izi ve en üst çerçeve.
 * Ham yığın izi, kaynak dosya adı ve kullanıcı verisi GİTMEZ. Sembolleştirme için uygulama çerçevelerinin konumu ayrıca gider (`frames`: en çok 5;
 * derlenmiş sınıf adı, yöntem adı ve satır, Web SDK'daki konum listesiyle aynı alanlar): R8/ProGuard ile karartılmış ad sunucuda yüklenen eşleme
 * dosyasıyla okuma anında özgün ada çözülür. Yerel (NDK) çökmede aynı `frames` listesi kütüphane + göreli adres taşır
 * (`libfoo.so~<build-id>`, satır = offset); sunucu bunu build-id ile eşleşen sembol dosyasıyla çözer. Kurallar Web ve Flutter
 * SDK'larıyla aynıdır; toplayıcı mesajı ayrıca temizler.
 */
internal object ErrorEvent {
    const val NAME = "fr_error"
    const val ORIGIN_UNCAUGHT = "uncaught_exception"
    const val ORIGIN_HANDLED = "handled"
    const val ORIGIN_MANUAL = "manual"
    /** Önceki açılışta sistemin kaydettiği ANR (`ApplicationExitInfo.REASON_ANR`). */
    const val ORIGIN_ANR = "anr"
    /** Önceki açılışta sistemin kaydettiği yerel (native) çökme (`ApplicationExitInfo.REASON_CRASH_NATIVE`). */
    const val ORIGIN_NATIVE_CRASH = "native_crash"
    const val MAX_MESSAGE = 200
    const val MAX_TYPE = 64
    const val MAX_FRAME = 160
    private const val FINGERPRINT_FRAMES = 5
    private const val MAX_LOCATIONS = 5
    private const val MAX_FUNCTION = 60
    // Toplayıcının `frames[].file` kuralı; `$` bu kümede yoktur ve Java tanımlayıcısında `~` olamaz: `$` → `~` geri döndürülebilir.
    private val LOCATION_FILE = Regex("^[A-Za-z0-9._~-]{1,128}$")

    // Çerçeve sistemi: bunlar parmak izine girmez (uygulama çerçevesi varsa); hepsi sistemse tüm çerçeveler kullanılır.
    private val FRAMEWORK_PREFIXES = listOf("java.", "javax.", "android.", "androidx.", "kotlin.", "kotlinx.", "dalvik.", "libcore.", "sun.", "com.android.internal.")
    // `$` karakter sınıfı içinde yazılır: ham dizgede `$ad` şablon sayılırdı.
    private val SYNTHETIC_SUFFIX = Regex("""[$][$]ExternalSyntheticLambda\d*|[$]\d+|[$][$]Lambda.*""")

    private val URL = Regex("""(?i)\b[a-z][a-z0-9+.-]*://[^\s"'<>]+""")
    private val EMAIL = Regex("""[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}""")
    private val UUID = Regex("""(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b""")
    private val TOKEN = Regex("""\b[A-Za-z0-9_\-+/=]{24,}\b""")
    private val NUMBER = Regex("""\+?\d[\d\s\-().]{5,}\d""")

    /** Mesajdan e-posta, URL, UUID, uzun sayı ve belirteçleri çıkarır; 200 karaktere kırpar. */
    fun scrub(message: String): String {
        var text = URL.replace(message, "[url]")
        text = EMAIL.replace(text, "[email]")
        text = UUID.replace(text, "[id]")
        text = TOKEN.replace(text) { if (it.value.any(Char::isDigit)) "[token]" else it.value }
        text = NUMBER.replace(text) { if (it.value.count(Char::isDigit) >= 7) "[num]" else it.value }
        return text.trim().replace(Regex("\\s+"), " ").take(MAX_MESSAGE)
    }

    /** Çerçeve: `sınıf.yöntem`; satır ve dosya yok, derleyicinin ürettiği lambda ekleri atılır. */
    fun frame(element: StackTraceElement): String = "${SYNTHETIC_SUFFIX.replace(element.className, "")}.${element.methodName}"

    fun frames(error: Throwable): List<String> = frames(error.stackTrace.asList())

    fun frames(elements: List<StackTraceElement>): List<String> {
        val all = elements.map { it.className to frame(it) }
        val app = all.filter { (cls, _) -> !isFramework(cls) }
        return (if (app.isNotEmpty()) app else all).map { it.second }
    }

    private fun isFramework(className: String): Boolean = FRAMEWORK_PREFIXES.any { className.startsWith(it) }

    /**
     * Sembolleştirme konumları: uygulama çerçevelerinin (çerçeve sistemi dışı) ilk beşi; derlenmiş sınıf adı olduğu gibi (`$` → `~`), yöntem adı ve
     * satır. Satırı bilinmeyen (yerel yöntem, satır tablosu atılmış) ya da toplayıcı kuralına sığmayan çerçeve konum listesine girmez.
     */
    fun locations(elements: List<StackTraceElement>): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        for (element in elements) {
            if (out.size >= MAX_LOCATIONS) break
            if (isFramework(element.className) || element.lineNumber < 1) continue
            val file = element.className.replace('$', '~')
            if (!LOCATION_FILE.matches(file)) continue
            val location = LinkedHashMap<String, Any?>()
            location["file"] = file
            location["line"] = element.lineNumber.coerceAtMost(10_000_000)
            location["column"] = 0
            if (element.methodName.isNotEmpty() && element.methodName.length <= MAX_FUNCTION) location["function"] = element.methodName
            out.add(location)
        }
        return out
    }

    /**
     * Yerel (NDK) çerçevenin parmak izi ve üst çerçeve gösterimi: `libfoo.so+0x12a4`. Kütüphane + göreli adres kurulumdan
     * kuruluma değişmez (ASLR ham adresi değiştirir, offset'i değiştirmez), bu yüzden gruplama kararlıdır.
     */
    fun nativeFrame(frame: NativeFrame): String = "${frame.library}+0x${frame.relativePc.toString(16)}"

    /**
     * Yerel çerçevelerin sembolleştirme konumları. Toplayıcı sözleşmesinde yerel çerçeveye ayrı alan yoktur; kimlik dosya adına
     * `~` ile eklenir (`libfoo.so~<build-id>`), göreli adres `line` alanına yazılır, `column` 0'dır ve `function` gönderilmez.
     * JVM çerçevesi her zaman `function` taşıdığı için iki biçim sunucuda karışmaz.
     *
     * Sınır: sözleşme `line` için en çok 10.000.000 kabul eder; daha büyük offset taşıyan çerçeve konum listesine girmez
     * (parmak izinde ve üst çerçevede yine görünür). Aynı şekilde 128 karakteri aşan dosya adı da atlanır.
     */
    fun nativeLocations(frames: List<NativeFrame>): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        for (frame in frames) {
            if (out.size >= MAX_LOCATIONS) break
            if (frame.relativePc < 1 || frame.relativePc > 10_000_000) continue
            val file = if (frame.buildId != null) "${frame.library}~${frame.buildId}" else frame.library
            if (!LOCATION_FILE.matches(file)) continue
            val location = LinkedHashMap<String, Any?>()
            location["file"] = file
            location["line"] = frame.relativePc.toInt()
            location["column"] = 0
            out.add(location)
        }
        return out
    }

    /** Yerel çökme gövdesi; çerçeve yoksa (tombstone okunamadı) konum gitmez, olay yine raporlanır. */
    fun buildNative(type: String, message: String, frames: List<NativeFrame>, fatal: Boolean, appVersion: String?): Map<String, Any?> {
        val labels = frames.map(::nativeFrame)
        val out = LinkedHashMap<String, Any?>()
        out["error_type"] = type
        if (message.isNotEmpty()) out["message"] = message
        out["fingerprint"] = fingerprint(type, labels, message)
        labels.firstOrNull()?.let { out["top_frame"] = it.take(MAX_FRAME) }
        out["frame_count"] = labels.size.coerceAtMost(1000)
        if (!appVersion.isNullOrEmpty() && appVersion.length <= 32) out["app_version"] = appVersion
        out["handled"] = false
        out["fatal"] = fatal
        out["origin"] = ORIGIN_NATIVE_CRASH
        val locations = nativeLocations(frames)
        if (locations.isNotEmpty()) out["frames"] = locations
        return out
    }

    fun fingerprint(type: String, frames: List<String>, message: String): String {
        val basis = if (frames.isNotEmpty()) frames.take(FINGERPRINT_FRAMES).joinToString("|") else message.replace(Regex("\\d+"), "#")
        val digest = MessageDigest.getInstance("SHA-256").digest("$type|$basis".toByteArray(Charsets.UTF_8))
        return digest.take(16).joinToString("") { "%02x".format(it) }
    }

    /** Hata gövdesi; sözleşme alanlarının tamamı. `appVersion` ≤32 karakterse eklenir. */
    fun properties(error: Throwable, origin: String, fatal: Boolean, appVersion: String?): Map<String, Any?> {
        val type = (error.javaClass.simpleName.ifEmpty { error.javaClass.name.substringAfterLast('.') }).take(MAX_TYPE).ifEmpty { "Error" }
        return build(type, scrub(error.message ?: ""), error.stackTrace.asList(), origin, fatal, appVersion)
    }

    /** Throwable olmayan kaynaklar (ANR izi, yerel çökme kaydı) için ortak gövde; tür ve mesaj çağıranın sabit özetidir. */
    fun build(type: String, message: String, elements: List<StackTraceElement>, origin: String, fatal: Boolean, appVersion: String?): Map<String, Any?> {
        val frames = frames(elements)
        val out = LinkedHashMap<String, Any?>()
        out["error_type"] = type
        if (message.isNotEmpty()) out["message"] = message
        out["fingerprint"] = fingerprint(type, frames, message)
        frames.firstOrNull()?.let { out["top_frame"] = it.take(MAX_FRAME) }
        out["frame_count"] = frames.size.coerceAtMost(1000)
        if (!appVersion.isNullOrEmpty() && appVersion.length <= 32) out["app_version"] = appVersion
        out["handled"] = origin == ORIGIN_HANDLED || origin == ORIGIN_MANUAL
        out["fatal"] = fatal
        out["origin"] = origin
        val locations = locations(elements)
        if (locations.isNotEmpty()) out["frames"] = locations
        return out
    }
}

/**
 * Hata fırtınası sınırı: süreç başına en çok [maxEvents] olay, aynı parmak izi için en çok [maxPerFingerprint]. Örnekleme [sampleRate] ile
 * (0..1); rastgele kaynak test için verilebilir.
 */
internal class ErrorLimiter(
    private val maxEvents: Int = 20,
    private val maxPerFingerprint: Int = 3,
    private val sampleRate: Double = 1.0,
    private val random: () -> Double = Math::random,
) {
    private var total = 0
    private val perFingerprint = HashMap<String, Int>()

    @Synchronized
    fun allow(fingerprint: String): Boolean {
        if (total >= maxEvents) return false
        if (sampleRate < 1.0 && random() >= sampleRate) return false
        val seen = perFingerprint[fingerprint] ?: 0
        if (seen >= maxPerFingerprint) return false
        perFingerprint[fingerprint] = seen + 1
        total++
        return true
    }
}
