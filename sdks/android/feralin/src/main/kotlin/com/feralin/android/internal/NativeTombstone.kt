package com.feralin.android.internal

/**
 * Yerel (NDK) çökme çerçevesi: hangi kütüphanede, kütüphane içinde hangi göreli adreste. Ham bellek adresi taşınmaz; sunucu
 * sembolleştirmesi için gereken yalnız modül kimliği ve offset'tir.
 */
internal data class NativeFrame(
    /** Kütüphanenin taban adı (`libfoo.so`). */
    val library: String,
    /** ELF `.note.gnu.build-id` değeri (onaltılı); kütüphane `--build-id` olmadan bağlanmışsa null. */
    val buildId: String?,
    /** Kütüphane içindeki göreli adres (`rel_pc`). */
    val relativePc: Long,
)

/**
 * `ApplicationExitInfo.getTraceInputStream()` yerel çökmede (API 31+) tombstone'u **protobuf** olarak döner (ANR'de ise düz
 * metin; onu [ProcessExits.mainThreadFrames] okur). Buradaki ayrıştırıcı tombstone şemasının tamamını bilmez ve bilmek
 * zorunda da değildir: protobuf tel biçimi (wire format) kendi kendini tanımlar, bu yüzden gövde yürütülür ve yalnız
 * **`BacktraceFrame` şekline uyan** alt iletiler toplanır.
 *
 * Şekil ölçütü (AOSP `system/core/debuggerd/proto/tombstone.proto`, `BacktraceFrame`): alan 1 = `rel_pc` (varint),
 * alan 6 = `file_name` (kütüphane yolu), alan 8 = `build_id` (onaltılı metin). Bir alt ileti ancak hatasız çözülüyorsa,
 * `rel_pc` makul aralıktaysa ve `file_name` `.so` ile biten bir yol ise çerçeve sayılır. Ölçüt tutmazsa çerçeve üretilmez:
 * uydurma adres ya da kütüphane adı yazılmaz, olay bugünkü gibi çerçevesiz gider.
 *
 * Çerçeveler ait oldukları alt iletiye (iş parçacığına) göre gruplanır ve **ilk grup** kullanılır: `debuggerd` tombstone'a
 * önce çöken iş parçacığını yazar. Gruplama sırası cihazda doğrulanmadı; yanlış grup seçilse bile çerçeveler gerçek bir
 * yığın izinden gelir, uydurma değildir.
 *
 * Gizlilik: yoldan yalnız taban ad alınır (`/data/app/~~rastgele==/paket-1/lib/arm64/libfoo.so` → `libfoo.so`); kurulum
 * dizini, paket yolu, kayıt tamponları, kayıt adresleri ve bellek dökümü okunmaz ve olaya girmez.
 */
internal object NativeTombstone {
    /** Tombstone protobuf'undan en çok bu kadar bayt okunur; gerisi atılır (bellek dökümü ve kayıt tamponları sonda durur). */
    const val MAX_BYTES = 1024 * 1024
    /** Olaya giren en çok çerçeve (`fr_error` sözleşmesi en çok 5 konum taşır). */
    const val MAX_FRAMES = 5
    /** Bir gruptan okunan en çok çerçeve; derin yığınlarda gereksiz iş yapılmaz. */
    private const val MAX_FRAMES_PER_GROUP = 64
    /** İç içe ileti derinliği sınırı: bozuk gövde özyinelemeyi patlatmasın. */
    private const val MAX_DEPTH = 6
    /** Göreli adres üst sınırı (256 MiB): daha büyüğü kütüphane içi offset olamaz, yanlış çözülmüş alandır. */
    private const val MAX_REL_PC = 256L * 1024 * 1024
    private const val FIELD_REL_PC = 1
    private const val FIELD_FILE_NAME = 6
    private const val FIELD_BUILD_ID = 8

    private val LIBRARY = Regex("^[A-Za-z0-9._-]{1,96}\\.so$")
    private val BUILD_ID = Regex("^[0-9a-f]{16,128}$")

    /** Tombstone gövdesinden çöken iş parçacığının çerçeveleri; ayrıştırılamazsa boş liste. */
    fun frames(bytes: ByteArray): List<NativeFrame> {
        val groups = ArrayList<List<NativeFrame>>()
        try {
            collect(bytes, 0, bytes.size, 0, groups)
        } catch (_: RuntimeException) {
            // Bozuk ya da beklenmedik biçim: çerçeve gönderilmez.
            return emptyList()
        }
        val first = groups.firstOrNull { it.isNotEmpty() } ?: return emptyList()
        return first.take(MAX_FRAMES)
    }

    /** Bir ileti bölgesini yürütür; doğrudan altındaki `BacktraceFrame` benzeri alt iletileri tek grup olarak toplar. */
    private fun collect(buf: ByteArray, from: Int, to: Int, depth: Int, out: MutableList<List<NativeFrame>>) {
        if (depth > MAX_DEPTH) return
        val local = ArrayList<NativeFrame>()
        var at = from
        while (at < to) {
            val tag = readVarint(buf, at, to) ?: return
            at = tag.next
            val field = (tag.value ushr 3).toInt()
            when ((tag.value and 7L).toInt()) {
                0 -> at = (readVarint(buf, at, to) ?: return).next
                1 -> at += 8
                2 -> {
                    val len = readVarint(buf, at, to) ?: return
                    val start = len.next
                    val end = start + len.value.toInt()
                    if (len.value < 0 || end > to || end < start) return
                    val frame = if (field > 0) asFrame(buf, start, end) else null
                    if (frame != null) {
                        if (local.size < MAX_FRAMES_PER_GROUP) local.add(frame)
                    } else if (end > start) {
                        collect(buf, start, end, depth + 1, out)
                    }
                    at = end
                }
                5 -> at += 4
                else -> return
            }
            if (at > to) return
        }
        if (local.isNotEmpty()) out.add(local)
    }

    /** Alt ileti `BacktraceFrame` şekline uyuyor mu; uymuyorsa null. */
    private fun asFrame(buf: ByteArray, from: Int, to: Int): NativeFrame? {
        var relPc: Long = -1
        var fileName: String? = null
        var buildId: String? = null
        var at = from
        while (at < to) {
            val tag = readVarint(buf, at, to) ?: return null
            at = tag.next
            val field = (tag.value ushr 3).toInt()
            when ((tag.value and 7L).toInt()) {
                0 -> {
                    val value = readVarint(buf, at, to) ?: return null
                    if (field == FIELD_REL_PC) relPc = value.value
                    at = value.next
                }
                1 -> at += 8
                2 -> {
                    val len = readVarint(buf, at, to) ?: return null
                    val start = len.next
                    val end = start + len.value.toInt()
                    if (len.value < 0 || len.value > 4096 || end > to || end < start) return null
                    if (field == FIELD_FILE_NAME || field == FIELD_BUILD_ID) {
                        val text = String(buf, start, end - start, Charsets.UTF_8)
                        if (field == FIELD_FILE_NAME) fileName = text else buildId = text
                    }
                    at = end
                }
                5 -> at += 4
                else -> return null
            }
            if (at > to) return null
        }
        if (at != to) return null
        if (relPc < 1 || relPc > MAX_REL_PC) return null
        val library = libraryName(fileName ?: return null) ?: return null
        val id = buildId?.lowercase()?.takeIf { BUILD_ID.matches(it) }
        return NativeFrame(library, id, relPc)
    }

    /** Yoldan kütüphane taban adı; `.so` ile bitmiyorsa (çalıştırılabilir, `[vdso]`, anonim eşleme) null. */
    fun libraryName(path: String): String? {
        // APK içinden eşlenen kütüphane: `.../base.apk!/lib/arm64-v8a/libfoo.so`.
        val tail = path.substringAfterLast("!/").substringAfterLast('/')
        return tail.takeIf { LIBRARY.matches(it) }
    }

    private class Varint(val value: Long, val next: Int)

    /** Protobuf varint; 10 bayttan uzun ya da kesik değer null döner. */
    private fun readVarint(buf: ByteArray, from: Int, to: Int): Varint? {
        var result = 0L
        var shift = 0
        var at = from
        while (at < to && shift <= 63) {
            val byte = buf[at].toInt()
            result = result or ((byte and 0x7f).toLong() shl shift)
            at++
            if (byte and 0x80 == 0) return Varint(result, at)
            shift += 7
        }
        return null
    }
}
