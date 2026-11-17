package com.feralin.android.internal

/**
 * Önceki açılışın sistem kaydı (`ApplicationExitInfo`, API 30+) için Android'den bağımsız görünüm; saf JVM'de sınanır. Ham iz ve sistem açıklaması
 * olaya girmez: ANR izinden yalnız ana iş parçacığının `at sınıf.yöntem(dosya:satır)` çerçeveleri, açıklamadan yalnız sabit bir özet alınır.
 */
internal data class ExitRecord(
    val reason: Int,
    val timestampMs: Long,
    val description: String?,
    val status: Int,
    /** ANR izinin metni (yalnız `REASON_ANR`; okunabildiyse ve sınır içinde). */
    val trace: String?,
    /** Yerel çökmenin tombstone protobuf'u (yalnız `REASON_CRASH_NATIVE`, API 31+; okunabildiyse ve sınır içinde). */
    val tombstone: ByteArray? = null,
)

internal object ProcessExits {
    /** `ApplicationExitInfo.REASON_CRASH_NATIVE` (resmî sabit değeri 5). */
    const val REASON_CRASH_NATIVE = 5
    /** `ApplicationExitInfo.REASON_ANR` (resmî sabit değeri 6). */
    const val REASON_ANR = 6
    const val TYPE_ANR = "ApplicationNotResponding"
    const val TYPE_NATIVE = "NativeCrash"
    /** Tek açılışta raporlanan en çok kayıt; sistem halka tamponu eski kayıtları da döndürebilir. */
    const val MAX_REPORTS = 5
    /** Bundan eski kayıt raporlanmaz (toplayıcı 90 günden eskiyi zaten reddeder). */
    const val MAX_AGE_MS = 30L * 24 * 3_600_000
    /** ANR izinden en çok bu kadar karakter okunur; ana iş parçacığı izin başındadır. */
    const val MAX_TRACE_CHARS = 512 * 1024

    private val THREAD_HEADER = Regex("""^"([^"]*)"\s""")
    private val FRAME_LINE = Regex("""^\s+at ([A-Za-z0-9_$.<>\-]+)\.([A-Za-z0-9_$<>\-]+)\((.*)\)\s*$""")

    private val SIGNALS = mapOf(
        4 to "SIGILL",
        5 to "SIGTRAP",
        6 to "SIGABRT",
        7 to "SIGBUS",
        8 to "SIGFPE",
        11 to "SIGSEGV",
        31 to "SIGSYS",
    )

    /** ANR izinden ana iş parçacığının Java çerçeveleri; iş parçacığı yoksa boş. Yerel (`native:`) satırlar ve kilit notları atlanır. */
    fun mainThreadFrames(trace: String): List<StackTraceElement> {
        val out = ArrayList<StackTraceElement>()
        var inMain = false
        for (raw in trace.lineSequence()) {
            val header = THREAD_HEADER.find(raw)
            if (header != null) {
                if (inMain) break
                inMain = header.groupValues[1] == "main"
                continue
            }
            if (!inMain) continue
            if (raw.isBlank()) break
            val match = FRAME_LINE.matchEntire(raw) ?: continue
            val location = match.groupValues[3]
            val file = location.substringBefore(':').takeIf { it.isNotEmpty() && it != "Native method" && it != "Unknown Source" }
            val line = when {
                location == "Native method" -> -2
                ':' in location -> location.substringAfterLast(':').toIntOrNull() ?: -1
                else -> -1
            }
            out.add(StackTraceElement(match.groupValues[1], match.groupValues[2], file, line))
            if (out.size >= 64) break
        }
        return out
    }

    /** Sistem açıklamasının sabit özeti: pencere adı, bileşen adı ve süre gibi ayrıntı gitmez. */
    fun anrSummary(description: String?): String {
        val text = description ?: return "ANR"
        return when {
            text.contains("Input dispatching timed out", ignoreCase = true) -> "Input dispatching timed out"
            text.contains("Broadcast of Intent", ignoreCase = true) || text.contains("broadcast", ignoreCase = true) -> "Broadcast receiver timed out"
            text.contains("executing service", ignoreCase = true) || text.contains("startForegroundService", ignoreCase = true) -> "Service timed out"
            text.contains("ContentProvider", ignoreCase = true) -> "Content provider timed out"
            text.contains("job", ignoreCase = true) -> "Job timed out"
            else -> "ANR"
        }
    }

    fun signalSummary(status: Int): String = SIGNALS[status]?.let { "Fatal signal $it" } ?: "Fatal signal"

    /**
     * Kayıttan `fr_error` gövdesi; desteklenmeyen neden (Java çökmesi zaten yakalanmamış istisna işleyicisindedir, bellek ve kullanıcı kaynaklı
     * sonlanmalar hata değildir) için `null`. Yerel çökmede, tombstone protobuf'u okunabildiyse çöken iş parçacığının çerçeveleri
     * kütüphane + göreli adres olarak gider (sunucuda build-id ile eşleşen sembol dosyasıyla çözülür); okunamazsa olay çerçevesiz gider.
     */
    fun properties(record: ExitRecord, appVersion: String?): Map<String, Any?>? = when (record.reason) {
        REASON_ANR -> ErrorEvent.build(
            TYPE_ANR,
            anrSummary(record.description),
            record.trace?.let(::mainThreadFrames) ?: emptyList(),
            ErrorEvent.ORIGIN_ANR,
            fatal = true,
            appVersion = appVersion,
        )
        REASON_CRASH_NATIVE -> ErrorEvent.buildNative(
            TYPE_NATIVE,
            signalSummary(record.status),
            record.tombstone?.let(NativeTombstone::frames) ?: emptyList(),
            fatal = true,
            appVersion = appVersion,
        )
        else -> null
    }

    /**
     * Raporlanacak kayıtlar: işaretten ([checkedAfterMs]) yeni, [nowMs]'e göre 30 günden eski olmayan ANR ve yerel çökmeler, en eskiden yeniye,
     * en çok [MAX_REPORTS]. İşaret yoksa (`null`) özellik bu kurulumda ilk kez açılıyordur: SDK'dan önceki geçmiş raporlanmaz.
     */
    fun select(records: List<ExitRecord>, checkedAfterMs: Long?, nowMs: Long): List<ExitRecord> {
        if (checkedAfterMs == null) return emptyList()
        return records
            .filter { (it.reason == REASON_ANR || it.reason == REASON_CRASH_NATIVE) && it.timestampMs > checkedAfterMs && it.timestampMs >= nowMs - MAX_AGE_MS }
            .sortedBy { it.timestampMs }
            .takeLast(MAX_REPORTS)
    }
}
