package com.feralin.android.internal

import com.feralin.android.Consent
import com.feralin.android.FeralinConfig
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

/**
 * L6 (dalga 13): kurulum kimliği (ADR-0007), `fr_group`, `fr_user_properties`, global özellikler ve önceki açılışın ANR / yerel çökme kayıtları.
 * Sözleşme React Native (`core.ts`), Unity (`FeralinClient.Contracts.cs`), Swift ve Flutter karşılıklarıyla aynıdır.
 */
class IdentityAndExitTest {
    private val worker = ManualWorker()
    private val transport = FakeTransport()
    private val store = MemoryEventStore()
    private var version = "2.0.0"

    private fun engine(consent: Consent?): FeralinEngine {
        val created = FeralinEngine(
            config = FeralinConfig(projectKey = "pk_test_unit", collectUrl = "https://collect.example.com", consent = consent),
            storeProvider = { store },
            transport = transport,
            referrer = { it(null) },
            appContext = { AppContext("tr-TR", "Europe/Istanbul", version, "42") },
            state = worker,
            net = worker,
            clock = { worker.now },
            random = Random(7),
        )
        created.start()
        worker.drain()
        return created
    }

    private val AD = Consent(analytics = true, advertising = true)
    private val ANALYTICS = Consent(analytics = true)

    private fun queued(): List<JSONObject> = store.peek(1000).map { JSONObject(it.payload) }
    private fun queued(name: String) = queued().filter { it.getString("event_name") == name }

    private fun FeralinEngine.install(): String? {
        var out: String? = "unset"
        installIdentifier { out = it }
        worker.drain()
        return out
    }

    @Test
    fun kurulumKimligiYalnizReklamOlcumuIzniyleUretilirKalicidirVeSilinir() {
        val sdk = engine(ANALYTICS)
        assertNull("reklam ölçümü izni yoksa kimlik yok", sdk.install())
        assertNull(store.get(FeralinEngine.KEY_INSTALL_ID))

        sdk.setConsent(AD)
        worker.drain()
        val first = sdk.install()
        assertNotNull(first)
        assertTrue(first!!.matches(Regex("^[0-9A-HJKMNP-TV-Z]{26}$")))
        assertEquals("aynı kurulum aynı kimliği verir", first, sdk.install())
        assertEquals(first, store.get(FeralinEngine.KEY_INSTALL_ID))

        // Yeniden başlatma: kimlik diskten okunur.
        val again = engine(AD)
        assertEquals(first, again.install())

        // Çıkış kimliği yeniler.
        again.reset()
        worker.drain()
        assertNull(store.get(FeralinEngine.KEY_INSTALL_ID))
        val renewed = again.install()
        assertNotEquals(first, renewed)

        // Analitik izni geri çekilince kimlik silinir ve verilmez.
        again.setConsent(Consent(analytics = false))
        worker.drain()
        assertNull(store.get(FeralinEngine.KEY_INSTALL_ID))
        assertNull(again.install())
    }

    @Test
    fun kurulumKimligiIzinBekleniyorkenDiskeYazilmaz() {
        val sdk = engine(null)
        assertNull(sdk.install())
        assertNull(store.get(FeralinEngine.KEY_INSTALL_ID))
    }

    @Test
    fun grupVeKullaniciOzellikleriOlaySozlesmesi() {
        val sdk = engine(ANALYTICS)
        assertNotNull(sdk.group("acct_42", mapOf("plan" to "pro", "seats" to 5, "bad key" to 1)))
        assertNull("boş grup kimliği", sdk.group("", null))
        assertNull("129 karakter", sdk.group("g".repeat(129), null))
        assertNull("yalnız boşluk", sdk.group("   ", null))
        assertNull("e-posta biçimli grup kimliği", sdk.group("ayse@example.com", null))
        assertNotNull(sdk.setUserProperties(mapOf("tier" to "gold", "beta" to true, "email" to "x", "firstName" to "Ayşe", "note" to "a@b.co", "nested" to mapOf("a" to 1))))
        assertNull("geçerli özellik yok", sdk.setUserProperties(mapOf("bad key" to 1)))
        assertNull("yalnız kişisel veri anahtarı", sdk.setUserProperties(mapOf("phoneNumber" to "5551112233")))
        worker.drain()
        val group = queued(FeralinEngine.EVENT_GROUP).single().getJSONObject("properties")
        assertEquals("acct_42", group.getString("group_id"))
        assertEquals("pro", group.getString("plan"))
        assertEquals(5, group.getInt("seats"))
        assertFalse(group.has("bad key"))
        // Grup özelliği group_id'yi ezemez.
        sdk.group("acct_43", mapOf("group_id" to "spoof"))
        worker.drain()
        assertEquals("acct_43", queued(FeralinEngine.EVENT_GROUP).last().getJSONObject("properties").getString("group_id"))
        val user = queued(FeralinEngine.EVENT_USER_PROPERTIES).single().getJSONObject("properties")
        assertEquals("gold", user.getString("tier"))
        assertTrue(user.getBoolean("beta"))
        // Ortak kural (ProfileRules): kişisel veriye benzeyen anahtar, e-posta biçimli değer ve iç içe değer düşer.
        for (key in listOf("email", "firstName", "note", "nested")) assertFalse(key, user.has(key))
    }

    @Test
    fun grupVeKullaniciOzellikleriIzinsizUretilmez() {
        val sdk = engine(null)
        assertNull(sdk.group("acct_42", null))
        assertNull(sdk.setUserProperties(mapOf("tier" to "gold")))
        worker.drain()
        assertEquals(0, store.size())
    }

    @Test
    fun globalOzelliklerHerOlayaEklenirOlayinKendisiOnceGelirResetSiler() {
        val sdk = engine(ANALYTICS)
        val accepted = sdk.setGlobalProperties(mapOf("app_theme" to "dark", "store" to "play", "fr_click" to "x", "verified" to true, "receipt" to "r", "bad key" to 1))
        assertEquals(2, accepted)
        sdk.track("screen_view", mapOf("screen_name" to "home", "store" to "override"))
        sdk.group("acct_1", null)
        worker.drain()
        val screen = queued("screen_view").single().getJSONObject("properties")
        assertEquals("dark", screen.getString("app_theme"))
        assertEquals("olayın kendi özelliği önce gelir", "override", screen.getString("store"))
        for (key in listOf("fr_click", "verified", "receipt")) assertFalse(key, screen.has(key))
        assertFalse("fr_ sistem olayına global eklenmez", queued(FeralinEngine.EVENT_GROUP).single().getJSONObject("properties").has("app_theme"))

        // Yeni çağrı birleştirir; değeri null olan anahtar silinir, null harita ve clearGlobalProperties hepsini temizler.
        assertEquals(1, sdk.setGlobalProperties(mapOf("store" to "amazon", "userEmail" to "x")))
        sdk.track("after_merge", null)
        sdk.setGlobalProperties(mapOf("app_theme" to null))
        sdk.track("after_delete", null)
        sdk.setGlobalProperties(null)
        sdk.track("after_clear", null)
        sdk.setGlobalProperties(mapOf("store" to "play"))
        sdk.clearGlobalProperties()
        sdk.track("after_clear_call", null)
        worker.drain()
        val merged = queued("after_merge").single().getJSONObject("properties")
        assertEquals("amazon", merged.getString("store"))
        assertEquals("dark", merged.getString("app_theme"))
        assertFalse(merged.has("userEmail"))
        val deleted = queued("after_delete").single().getJSONObject("properties")
        assertEquals("amazon", deleted.getString("store"))
        assertFalse(deleted.has("app_theme"))
        assertFalse(queued("after_clear").single().has("properties"))
        assertFalse(queued("after_clear_call").single().has("properties"))

        sdk.setGlobalProperties(mapOf("app_theme" to "dark"))
        sdk.reset()
        worker.drain()
        sdk.track("after_reset", null)
        worker.drain()
        assertFalse("çıkış global özellikleri siler", queued("after_reset").single().has("properties"))
    }

    @Test
    fun globalOzelliklerYuzOzellikSiniriniAsmaz() {
        val sdk = engine(ANALYTICS)
        assertEquals("global harita en çok 50 anahtar", 50, sdk.setGlobalProperties((1..60).associate { "g$it" to it }))
        sdk.track("wide", (1..70).associate { "p$it" to it })
        worker.drain()
        val props = queued("wide").single().getJSONObject("properties")
        assertEquals(100, props.length())
        assertTrue((1..70).all { props.has("p$it") })
    }

    private val anrTrace = """
        ----- pid 4321 at 2026-11-13 10:00:00.000000000+0300 -----
        Cmd line: com.feralin.sample

        "Signal Catcher" daemon prio=10 tid=4 Runnable
          | group="system" sCount=0
          at dalvik.system.VMStack.getThreadStackTrace(Native method)

        "main" prio=5 tid=1 Sleeping
          | group="main" sCount=1 ucsCount=0 flags=1 obj=0x72e1c2a0 self=0xb400007a
          | sysTid=4321 nice=-10 cgrp=top-app sched=0/0 handle=0x7b
          at java.lang.Thread.sleep(Native method)
          - sleeping on <0x0a1b2c3d> (a java.lang.Object)
          at java.lang.Thread.sleep(Thread.java:450)
          - locked <0x0a1b2c3d> (a java.lang.Object)
          at com.feralin.sample.MainActivity${'$'}a.onClick(SourceFile:12)
          at a.b.c(SourceFile:7)
          at android.view.View.performClick(View.java:7659)
          native: #00 pc 000000000005a1b8  /apex/com.android.runtime/lib64/bionic/libc.so (nanosleep+8)

        "FinalizerDaemon" daemon prio=5 tid=6 Waiting
          at com.example.Other.secret(Other.kt:99)
    """.trimIndent()

    @Test
    fun anrIzindenYalnizAnaIsParcacigiCercevesiAlinir() {
        val frames = ProcessExits.mainThreadFrames(anrTrace)
        assertEquals(listOf("java.lang.Thread", "java.lang.Thread", "com.feralin.sample.MainActivity\$a", "a.b", "android.view.View"), frames.map { it.className })
        assertEquals(-2, frames[0].lineNumber)
        assertEquals(12, frames[2].lineNumber)
        val props = ProcessExits.properties(ExitRecord(ProcessExits.REASON_ANR, 1L, "Input dispatching timed out (8a7b6c5 com.feralin.sample/com.feralin.sample.MainActivity (server) is not responding. Waited 5001ms for MotionEvent)", 0, anrTrace), "2.0.0")!!
        assertEquals(ProcessExits.TYPE_ANR, props["error_type"])
        assertEquals("sistem açıklamasından yalnız sabit özet", "Input dispatching timed out", props["message"])
        assertEquals("anr", props["origin"])
        assertEquals(true, props["fatal"])
        assertEquals(false, props["handled"])
        assertEquals("com.feralin.sample.MainActivity\$a.onClick", props["top_frame"])
        assertEquals("2.0.0", props["app_version"])
        @Suppress("UNCHECKED_CAST")
        val locations = props["frames"] as List<Map<String, Any?>>
        assertEquals(listOf("com.feralin.sample.MainActivity~a", "a.b"), locations.map { it["file"] })
        assertEquals(listOf(12, 7), locations.map { it["line"] })
        assertEquals(listOf("onClick", "c"), locations.map { it["function"] })
        val text = props.toString()
        for (leak in listOf("8a7b6c5", "Waited", "Other", "secret", "libc", "0x0a1b2c3d", "Signal Catcher", "4321")) assertFalse(leak, text.contains(leak))
    }

    @Test
    fun yerelCokmeYalnizSinyalAdiyla() {
        val props = ProcessExits.properties(ExitRecord(ProcessExits.REASON_CRASH_NATIVE, 1L, "crash in /data/app/~~x/lib/libgame.so", 11, null), null)!!
        assertEquals(ProcessExits.TYPE_NATIVE, props["error_type"])
        assertEquals("Fatal signal SIGSEGV", props["message"])
        assertEquals("native_crash", props["origin"])
        assertFalse(props.containsKey("frames"))
        assertFalse(props.toString().contains("libgame"))
        // Java çökmesi (4) yakalanmamış istisna işleyicisindedir; düşük bellek (3) hata değildir.
        assertNull(ProcessExits.properties(ExitRecord(4, 1L, null, 0, null), null))
        assertNull(ProcessExits.properties(ExitRecord(3, 1L, null, 0, null), null))
    }

    @Test
    fun kayitSecimiIsaretYasVeSinir() {
        val now = 1_780_000_000_000L
        val records = listOf(
            ExitRecord(ProcessExits.REASON_ANR, now - 1_000, null, 0, null),
            ExitRecord(ProcessExits.REASON_CRASH_NATIVE, now - 2_000, null, 11, null),
            ExitRecord(10, now - 500, null, 0, null),
            ExitRecord(ProcessExits.REASON_ANR, now - 40L * 86_400_000, null, 0, null),
            ExitRecord(ProcessExits.REASON_ANR, now - 9_000, null, 0, null),
        )
        assertTrue("ilk açılışta geçmiş raporlanmaz", ProcessExits.select(records, null, now).isEmpty())
        val chosen = ProcessExits.select(records, now - 5_000, now)
        assertEquals(listOf(now - 2_000, now - 1_000), chosen.map { it.timestampMs })
        val many = (1..9).map { ExitRecord(ProcessExits.REASON_ANR, now - it * 10L, null, 0, null) }
        assertEquals(ProcessExits.MAX_REPORTS, ProcessExits.select(many, 0L, now).size)
    }

    @Test
    fun oncekiAcilisinAnrsiIzinKararindanSonraBirKezGonderilir() {
        worker.now = 1_780_000_000_000L
        // İlk açılış: işaret yazılır, geçmiş raporlanmaz; sürüm kaydedilir.
        val first = engine(ANALYTICS)
        first.reportProcessExits { listOf(ExitRecord(ProcessExits.REASON_ANR, worker.now - 60_000, null, 0, anrTrace)) }
        worker.drain()
        assertTrue(queued(ErrorEvent.NAME).isEmpty())
        assertEquals(worker.now.toString(), store.get(FeralinEngine.KEY_EXIT_CHECKED_AT))
        assertEquals("2.0.0", store.get(FeralinEngine.KEY_LAST_APP_VERSION))

        // ANR olur, uygulama güncellenir, sonraki açılışta izin henüz yok: kayıt bekler, işaret ilerlemez.
        val anrAt = worker.now + 10_000
        worker.now += 60_000
        version = "2.1.0"
        val second = engine(null)
        second.reportProcessExits { listOf(ExitRecord(ProcessExits.REASON_ANR, anrAt, "Input dispatching timed out", 0, anrTrace)) }
        worker.drain()
        assertTrue(queued(ErrorEvent.NAME).isEmpty())
        assertNotEquals(anrAt.toString(), store.get(FeralinEngine.KEY_EXIT_CHECKED_AT))

        second.setConsent(ANALYTICS)
        worker.drain()
        val event = queued(ErrorEvent.NAME).single()
        assertEquals("olay zamanı sistemin kaydettiği çıkış zamanıdır", EventJson.formatTime(anrAt), event.getString("occurred_at"))
        val props = event.getJSONObject("properties")
        assertEquals("anr", props.getString("origin"))
        assertEquals("kayıt önceki açılışın sürümüyle (eşleme dosyası seçimi)", "2.0.0", props.getString("app_version"))
        assertEquals(anrAt.toString(), store.get(FeralinEngine.KEY_EXIT_CHECKED_AT))
        assertEquals("2.1.0", store.get(FeralinEngine.KEY_LAST_APP_VERSION))

        // Aynı kayıt bir sonraki açılışta yeniden gönderilmez.
        val third = engine(ANALYTICS)
        third.reportProcessExits { listOf(ExitRecord(ProcessExits.REASON_ANR, anrAt, null, 0, anrTrace)) }
        worker.drain()
        assertEquals(1, queued(ErrorEvent.NAME).size)
    }

    @Test
    fun analitikReddindeKayitGonderilmezVeSonradanDaGonderilmez() {
        worker.now = 1_780_000_000_000L
        store.put(FeralinEngine.KEY_EXIT_CHECKED_AT, (worker.now - 100_000).toString())
        val sdk = engine(Consent(analytics = false))
        sdk.reportProcessExits { listOf(ExitRecord(ProcessExits.REASON_CRASH_NATIVE, worker.now - 1_000, null, 6, null)) }
        worker.drain()
        assertEquals(0, store.size())
        assertEquals((worker.now - 1_000).toString(), store.get(FeralinEngine.KEY_EXIT_CHECKED_AT))
        sdk.setConsent(ANALYTICS)
        worker.drain()
        assertTrue(queued(ErrorEvent.NAME).isEmpty())
    }

    @Test
    fun okumaHatasiSdkyiDusurmez() {
        worker.now = 1_780_000_000_000L
        store.put(FeralinEngine.KEY_EXIT_CHECKED_AT, "1")
        val sdk = engine(ANALYTICS)
        sdk.reportProcessExits { throw SecurityException("yok") }
        worker.drain()
        assertNotNull(sdk.track("still_alive", null))
    }

    @Test
    fun yakalananHatadaSembollestirmeKonumlariGider() {
        val error = IllegalStateException("x").apply {
            stackTrace = arrayOf(
                StackTraceElement("android.os.Handler", "dispatchMessage", "Handler.java", 100),
                StackTraceElement("a.b\$c", "d", "SourceFile", 33),
                StackTraceElement("a.e", "f", "SourceFile", -1),
                StackTraceElement("x".repeat(130), "g", "SourceFile", 5),
                StackTraceElement("a.h", "m".repeat(61), "SourceFile", 8),
            )
        }
        @Suppress("UNCHECKED_CAST")
        val locations = ErrorEvent.properties(error, ErrorEvent.ORIGIN_HANDLED, false, null)["frames"] as List<Map<String, Any?>>
        assertEquals(listOf("a.b~c", "a.h"), locations.map { it["file"] })
        assertEquals(mapOf("file" to "a.b~c", "line" to 33, "column" to 0, "function" to "d"), locations[0])
        assertFalse("uzun yöntem adı kırpılmaz, alan düşer", locations[1].containsKey("function"))
    }
}
