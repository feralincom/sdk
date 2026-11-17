package com.feralin.android.internal

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.ByteArrayOutputStream

/**
 * M2 (dalga 16): yerel (NDK) çökme tombstone'undan kütüphane + göreli adres çıkarma ve `fr_error` gövdesine yazma. Girdi, AOSP
 * `tombstone.proto` şemasıyla aynı tel biçiminde elle kodlanmış protobuf'tur (test içindeki kodlayıcı); gerçek cihaz tombstone'u
 * ile doğrulama yapılmadı, bu yüzden ayrıştırıcının şekle uymayan girdide çerçeve üretmediği de ayrıca sınanır.
 */
class NativeTombstoneTest {
    private fun varint(out: ByteArrayOutputStream, value: Long) {
        var rest = value
        while (true) {
            val byte = (rest and 0x7f).toInt()
            rest = rest ushr 7
            if (rest == 0L) {
                out.write(byte)
                return
            }
            out.write(byte or 0x80)
        }
    }

    private fun tag(out: ByteArrayOutputStream, field: Int, wire: Int) = varint(out, (field.toLong() shl 3) or wire.toLong())

    private fun bytes(build: ByteArrayOutputStream.() -> Unit): ByteArray = ByteArrayOutputStream().apply(build).toByteArray()

    private fun ByteArrayOutputStream.sub(field: Int, payload: ByteArray) {
        tag(this, field, 2)
        varint(this, payload.size.toLong())
        write(payload)
    }

    private fun ByteArrayOutputStream.text(field: Int, value: String) = sub(field, value.toByteArray(Charsets.UTF_8))

    private fun ByteArrayOutputStream.number(field: Int, value: Long) {
        tag(this, field, 0)
        varint(this, value)
    }

    /** `BacktraceFrame`: 1 = rel_pc, 2 = pc, 6 = file_name, 8 = build_id. */
    private fun frame(relPc: Long, path: String, buildId: String?): ByteArray = bytes {
        number(1, relPc)
        number(2, 0x7f0000000000L + relPc)
        text(6, path)
        if (buildId != null) text(8, buildId)
    }

    /** `Thread`: 1 = id, 2 = name, 4 = current_backtrace (tekrarlı). */
    private fun thread(id: Long, name: String, frames: List<ByteArray>): ByteArray = bytes {
        number(1, id)
        text(2, name)
        for (f in frames) sub(4, f)
    }

    /** `Tombstone`: 5 = pid, 6 = tid, 17 = threads (map<uint32, Thread>). */
    private fun tombstone(threads: List<Pair<Long, ByteArray>>): ByteArray = bytes {
        number(5, 4242)
        number(6, 4242)
        for ((tid, body) in threads) {
            sub(17, bytes {
                number(1, tid)
                sub(2, body)
            })
        }
    }

    private val buildId = "353c6a3f50031067dffa07cd65734fec1809883b"

    @Test
    fun cokenIsParcaciginCerceveleriKutuphaneVeGoreliAdresOlarakOkunur() {
        val crashing = thread(4242, "main", listOf(
            frame(0x4704L, "/data/app/~~rastgele==/com.ornek-1/lib/arm64/libgame.so", buildId),
            frame(0x1180L, "/apex/com.android.runtime/lib64/bionic/libc.so", "AABBCCDDEEFF00112233445566778899"),
        ))
        val other = thread(4300, "worker", listOf(frame(0x900L, "/data/app/x/lib/arm64/libother.so", buildId)))
        val frames = NativeTombstone.frames(tombstone(listOf(4242L to crashing, 4300L to other)))
        assertEquals(2, frames.size)
        // Yoldan yalnız taban ad alınır: kurulum dizini olaya girmez.
        assertEquals(NativeFrame("libgame.so", buildId, 0x4704L), frames[0])
        // Build-id küçük harfe indirgenir.
        assertEquals("aabbccddeeff00112233445566778899", frames[1].buildId)
        assertEquals("libc.so", frames[1].library)
        assertFalse("başka iş parçacığının çerçevesi karışmaz", frames.any { it.library == "libother.so" })
    }

    @Test
    fun apkIcindenEslenenKutuphaneVeSembolsuzKutuphaneDogruOkunur() {
        val frames = NativeTombstone.frames(
            tombstone(listOf(1L to thread(1, "main", listOf(
                frame(0x2000L, "/data/app/com.ornek-1/base.apk!/lib/arm64-v8a/libunity.so", null),
                // `.so` olmayan eşlemeler (çalıştırılabilir, anonim bölge) çerçeve sayılmaz.
                frame(0x30L, "/system/bin/app_process64", buildId),
                frame(0x40L, "[vdso]", null),
            )))),
        )
        assertEquals(1, frames.size)
        assertEquals(NativeFrame("libunity.so", null, 0x2000L), frames[0])
        assertEquals("libfoo.so", NativeTombstone.libraryName("/x/y/libfoo.so"))
        assertNull(NativeTombstone.libraryName("/system/bin/linker64"))
        assertNull(NativeTombstone.libraryName("libfoo.so.1"))
    }

    @Test
    fun sekleUymayanGirdiCerceveUretmez() {
        // Rastgele bayt, ANR'ın düz metin izi ve boş gövde: uydurma kütüphane ya da adres yazılmaz.
        assertTrue(NativeTombstone.frames(ByteArray(0)).isEmpty())
        assertTrue(NativeTombstone.frames(ByteArray(256) { (it * 7).toByte() }).isEmpty())
        assertTrue(NativeTombstone.frames("\"main\" prio=5 tid=1 Sleeping\n  at a.b.c(SourceFile:12)\n".toByteArray()).isEmpty())
        // Göreli adresi 0 olan ya da sınır dışı çerçeve atılır (ELF başlığı çağrı adresi olamaz).
        assertTrue(NativeTombstone.frames(tombstone(listOf(1L to thread(1, "main", listOf(frame(0L, "/x/libgame.so", buildId)))))).isEmpty())
        assertTrue(NativeTombstone.frames(tombstone(listOf(1L to thread(1, "main", listOf(frame(1L shl 40, "/x/libgame.so", buildId)))))).isEmpty())
        // Kesik gövde: ayrıştırma hata vermez, çerçeve de üretmez.
        val full = tombstone(listOf(1L to thread(1, "main", listOf(frame(0x4704L, "/x/libgame.so", buildId)))))
        assertTrue(NativeTombstone.frames(full.copyOfRange(0, full.size / 2)).size <= 1)
    }

    @Test
    fun olayGovdesiKutuphaneVeOffsetTasir() {
        val record = ExitRecord(
            reason = ProcessExits.REASON_CRASH_NATIVE,
            timestampMs = 1L,
            description = "crash in /data/app/~~x/lib/libgame.so",
            status = 11,
            trace = null,
            tombstone = tombstone(listOf(1L to thread(1, "main", listOf(frame(0x4704L, "/data/app/x/lib/arm64/libgame.so", buildId))))),
        )
        val props = ProcessExits.properties(record, "1.4.2")!!
        assertEquals(ProcessExits.TYPE_NATIVE, props["error_type"])
        assertEquals("Fatal signal SIGSEGV", props["message"])
        assertEquals("native_crash", props["origin"])
        assertEquals("libgame.so+0x4704", props["top_frame"])
        assertEquals(1, props["frame_count"] as Int)
        @Suppress("UNCHECKED_CAST")
        val locations = props["frames"] as List<Map<String, Any?>>
        // Dosya alanı kütüphane + build-id taşır (toplayıcı sözleşmesinde yerel çerçeveye ayrı alan yoktur).
        assertEquals("libgame.so~$buildId", locations[0]["file"])
        assertEquals(0x4704, locations[0]["line"] as Int)
        assertEquals(0, locations[0]["column"] as Int)
        assertFalse("yerel çerçevede işlev adı gönderilmez", locations[0].containsKey("function"))
        // Sistem açıklamasındaki kurulum yolu olaya girmez.
        assertFalse(props.toString().contains("/data/app"))
        // Parmak izi kütüphane + offset üzerinden kararlıdır: aynı çökme aynı grubu verir, başka offset başka grubu.
        val same = ProcessExits.properties(record, "9.9.9")!!
        assertEquals(props["fingerprint"], same["fingerprint"])
        val moved = ProcessExits.properties(record.copy(tombstone = tombstone(listOf(1L to thread(1, "main", listOf(frame(0x5000L, "/x/libgame.so", buildId)))))), "1.4.2")!!
        assertFalse(props["fingerprint"] == moved["fingerprint"])
    }

    @Test
    fun sozlesmeSinirlariniAsanCerceveKonumListesineGirmez() {
        // Toplayıcı `line` için en çok 10.000.000 kabul eder; daha büyük offset konum olarak gönderilmez ama olay yine gider.
        val big = ProcessExits.properties(
            ExitRecord(ProcessExits.REASON_CRASH_NATIVE, 1L, null, 11, null, tombstone(listOf(1L to thread(1, "main", listOf(frame(20_000_000L, "/x/libbig.so", buildId)))))),
            null,
        )!!
        assertEquals("libbig.so+0x1312d00", big["top_frame"])
        assertFalse(big.containsKey("frames"))
    }
}
