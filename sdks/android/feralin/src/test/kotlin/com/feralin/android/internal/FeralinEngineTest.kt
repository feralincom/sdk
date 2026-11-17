package com.feralin.android.internal

import com.feralin.android.Consent
import com.feralin.android.DeferredDeepLink
import com.feralin.android.DeferredDeepLinkStatus
import com.feralin.android.FeralinConfig
import com.feralin.android.FlushResult
import com.feralin.android.SdkWrapper
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.random.Random

class FeralinEngineTest {
    private val worker = ManualWorker()
    private val transport = FakeTransport()
    private val store = MemoryEventStore()
    private var referrerReads = 0
    private var referrerResult: AttributionParams? = null
    private var heldReferrer: ((AttributionParams?) -> Unit)? = null
    private var holdReferrer = false

    private fun engine(consent: Consent?, batchSize: Int = 50, queueLimit: Int = 1000, installCode: String? = null): FeralinEngine {
        val created = FeralinEngine(
            config = FeralinConfig(
                projectKey = "pk_test_unit",
                collectUrl = "https://collect.example.com/",
                consent = consent,
                batchSize = batchSize,
                queueLimit = queueLimit,
                installCode = installCode,
            ),
            storeProvider = { store },
            transport = transport,
            referrer = {
                referrerReads++
                if (holdReferrer) heldReferrer = it else it(referrerResult)
            },
            appContext = { AppContext("tr-TR", "Europe/Istanbul", "1.2.3", "42") },
            state = worker,
            net = worker,
            clock = { worker.now },
            random = Random(7),
        )
        created.start()
        worker.drain()
        return created
    }

    private val GRANTED = Consent(analytics = true)
    private val GRANTED_AD = Consent(analytics = true, advertising = true)
    private val GRANTED_NO_AD = Consent(analytics = true, advertising = false)
    private val DENIED = Consent(analytics = false)

    private fun engineWith(consent: Consent, target: EventStore): FeralinEngine {
        val created = FeralinEngine(
            config = FeralinConfig("pk_test_unit", "https://collect.example.com", consent),
            storeProvider = { target },
            transport = transport,
            referrer = {
                referrerReads++
                it(referrerResult)
            },
            appContext = { AppContext("tr-TR", "Europe/Istanbul", "1.2.3", "42") },
            state = worker,
            net = worker,
            clock = { worker.now },
            random = Random(7),
        )
        created.start()
        worker.drain()
        return created
    }

    private fun FeralinEngine.flushNow(): FlushResult {
        var result: FlushResult? = null
        flush { result = it }
        worker.drain()
        return result!!
    }

    private fun sentEvents() = transport.requests.flatMap { it.events }

    private fun sentNames() = sentEvents().map { it.getString("event_name") }

    @Test
    fun izinBekleniyorkenOlayUretilmezVeReferrerOkunmaz() {
        val sdk = engine(consent = null)
        assertNull(sdk.track("purchase", null))
        worker.drain()
        assertEquals(0, store.size())
        assertEquals(0, referrerReads)
        assertNull("kimlik izinsiz diske yazılmaz", store.get(FeralinEngine.KEY_ANONYMOUS_ID))
        assertEquals(FlushResult.NONE, sdk.flushNow())
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun izinBekleniyorkenDepodakiKuyrukSilinmezOnaydaGonderilir() {
        store.add(StoredEvent("01OLDEVENT00000000000000000", "{\"event_id\":\"01OLDEVENT00000000000000000\"}"), 10)
        val sdk = engine(consent = null)
        sdk.flushNow()
        assertEquals(1, store.size())
        assertTrue(transport.requests.isEmpty())
        sdk.setConsent(GRANTED)
        worker.drain()
        sdk.flushNow()
        assertTrue(transport.requests.flatMap { it.events }.any { it.getString("event_id") == "01OLDEVENT00000000000000000" })
    }

    @Test
    fun izinReddedilinceKuyrukVeKimlikSilinir() {
        val sdk = engine(GRANTED)
        sdk.track("a", null)
        worker.drain()
        assertTrue(store.size() > 0)
        assertNotNull(store.get(FeralinEngine.KEY_ANONYMOUS_ID))
        sdk.setConsent(DENIED)
        worker.drain()
        assertEquals(0, store.size())
        assertNull(store.get(FeralinEngine.KEY_ANONYMOUS_ID))
        assertNull(sdk.track("b", null))
        assertEquals(FlushResult.NONE, sdk.flushNow())
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun acilistaBilinenRetKuyruguSiler() {
        store.add(StoredEvent("01OLDEVENT00000000000000000", "{}"), 10)
        store.put(FeralinEngine.KEY_ANONYMOUS_ID, "eski")
        engine(DENIED)
        assertEquals(0, store.size())
        assertNull(store.get(FeralinEngine.KEY_ANONYMOUS_ID))
    }

    @Test
    fun yolHaliSurerkenRetGelseBileAckSonrasiKuyrukBosKalir() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        sdk.track("a", null)
        sdk.flush(null)
        // state görevi çalıştı ama net sonucu işlenmeden izin reddedildi.
        sdk.setConsent(DENIED)
        worker.drain()
        assertEquals(0, store.size())
        assertNull(store.get(FeralinEngine.KEY_ANONYMOUS_ID))
    }

    @Test
    fun ilkAcilisKurulumBasinaBirKezUretilir() {
        val first = engine(GRANTED_AD)
        first.flushNow()
        assertEquals(listOf("app_first_open"), sentNames())
        assertEquals(1, referrerReads)
        val id = sentEvents().single().getString("event_id")
        assertEquals(id, store.get(FeralinEngine.KEY_FIRST_OPEN))

        // Aynı depoyla yeni süreç.
        val second = engine(GRANTED_AD)
        second.track("second_run", null)
        worker.drain()
        second.flushNow()
        assertEquals(listOf("app_first_open", "second_run"), sentNames())
        assertEquals("referrer kurulumda bir kez okunur", 1, referrerReads)
    }

    @Test
    fun ilkAcilisIzinSonrasinaErtelenirVeRetOnayDongusundeTekrarlanmaz() {
        val sdk = engine(consent = null)
        assertEquals(0, referrerReads)
        sdk.setConsent(DENIED)
        worker.drain()
        assertEquals(0, referrerReads)
        assertNull(store.get(FeralinEngine.KEY_FIRST_OPEN))
        sdk.setConsent(GRANTED)
        worker.drain()
        sdk.flushNow()
        sdk.setConsent(DENIED)
        worker.drain()
        sdk.setConsent(GRANTED)
        worker.drain()
        sdk.flushNow()
        assertEquals(listOf("app_first_open"), sentNames())
    }

    @Test
    fun kurulumKoduYalnizIlkOlaylaGider() {
        val sdk = engine(GRANTED, installCode = " abcde-fghjk ")
        sdk.track("purchase", mapOf("amount" to 1))
        sdk.flushNow()
        val events = sentEvents()
        assertEquals(listOf("app_first_open", "purchase"), events.map { it.getString("event_name") })
        assertEquals("abcde-fghjk", events[0].props().getString("fr_install_code"))
        assertFalse(events[1].props().has("fr_install_code"))
    }

    @Test
    fun bozukKurulumKoduGitmez() {
        // I ve O alfabede yoktur: yapılandırmadaki bozuk kod hiçbir olaya eklenmez.
        val sdk = engine(GRANTED, installCode = "ABCDEFGHIO")
        sdk.track("purchase", mapOf("amount" to 1))
        sdk.flushNow()
        assertFalse(transport.requests.single().body.contains("fr_install_code"))
        assertEquals(1, sentEvents().last().props().getInt("amount"))
    }

    @Test
    fun izinYokkenKurulumKoduHarcanmaz() {
        // İzin gelmeden olay üretilmez; kod izin sonrası ilk olayla gider.
        val sdk = engine(null, installCode = "ABCDE-FGHJK")
        sdk.track("early", null)
        sdk.setConsent(GRANTED)
        worker.drain()
        sdk.flushNow()
        val withCode = sentEvents().filter { it.props().has("fr_install_code") }
        assertEquals(1, withCode.size)
        assertEquals("ABCDE-FGHJK", withCode.single().props().getString("fr_install_code"))
    }

    @Test
    fun referrerdenYalnizIzinListesiTasinir() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_1&utm_source=ads&gclid=gizli&email=a%40b.c")
        val sdk = engine(GRANTED_AD)
        sdk.flushNow()
        val event = sentEvents().single()
        val props = event.props()
        assertEquals("play_install_referrer", props.getString("attribution_source"))
        assertEquals("clk_1", props.getString("fr_click"))
        assertEquals("ads", props.getString("utm_source"))
        assertFalse(transport.requests.single().body.contains("gclid"))
        assertFalse(transport.requests.single().body.contains("email"))
    }

    @Test
    fun organikReferrerKanitSayilmaz() {
        referrerResult = AttributionParams.parseQuery("utm_source=google-play&utm_medium=organic")
        val sdk = engine(GRANTED_AD)
        sdk.flushNow()
        val props = sentEvents().single().props()
        assertEquals("none", props.getString("attribution_source"))
        assertFalse(props.has("utm_source"))
    }

    @Test
    fun referrerYoksaKaynakNone() {
        referrerResult = null
        val sdk = engine(GRANTED)
        sdk.flushNow()
        val props = sentEvents().single().props()
        assertEquals("none", props.getString("attribution_source"))
        assertFalse(props.has("fr_click"))
    }

    @Test
    fun referrerKutuphanesiYoksaDusmez() {
        val sdk = FeralinEngine(
            config = FeralinConfig("pk_test_unit", "https://collect.example.com", GRANTED_AD),
            storeProvider = { store },
            transport = transport,
            referrer = { throw NoClassDefFoundError("com/android/installreferrer/api/InstallReferrerClient") },
            appContext = { AppContext(null, null, null, null) },
            state = worker,
            net = worker,
            clock = { worker.now },
        )
        sdk.start()
        worker.drain()
        sdk.flushNow()
        assertEquals("none", sentEvents().single().props().getString("attribution_source"))
    }

    @Test
    fun derinBaglantiHerAcilistaUretilirSorguTemizlenir() {
        val sdk = engine(GRANTED_AD)
        sdk.flushNow()
        transport.requests.clear()
        val url = "https://go.example.com/o/x?fr_click=clk_9&utm_campaign=yaz&token=SIR&email=a%40b.c#frag"
        sdk.handleLink(url)
        worker.drain()
        sdk.handleLink(url)
        worker.drain()
        sdk.flushNow()
        val events = sentEvents()
        assertEquals(listOf("deep_link_opened", "deep_link_opened"), events.map { it.getString("event_name") })
        val event = events.first()
        assertEquals("app_link", event.props().getString("attribution_source"))
        assertEquals("clk_9", event.props().getString("fr_click"))
        assertEquals("yaz", event.props().getString("utm_campaign"))
        assertEquals("https://go.example.com/o/x", event.getJSONObject("context").getString("page_url"))
        val body = transport.requests.joinToString { it.body }
        assertFalse(body.contains("SIR"))
        assertFalse(body.contains("frag"))
        assertFalse(body.contains("a@b.c"))
    }

    @Test
    fun izinBeklerkenGelenBaglantiOnaydaUretilirRetteUnutulur() {
        val pending = engine(consent = null)
        pending.handleLink("https://go.example.com/o?fr_click=clk_2")
        worker.drain()
        assertEquals("izin gelmeden hiçbir şey diske yazılmaz", 0, store.size())
        pending.setConsent(DENIED)
        worker.drain()
        pending.setConsent(GRANTED)
        worker.drain()
        pending.flushNow()
        assertFalse(sentNames().contains("deep_link_opened"))
    }

    @Test
    fun onaydaBekleyenBaglantiIlkAcilisaKanitOlur() {
        val sdk = engine(consent = null)
        sdk.handleLink("https://go.example.com/o?fr_click=clk_3")
        worker.drain()
        sdk.setConsent(GRANTED_AD)
        worker.drain()
        sdk.flushNow()
        val byName = sentEvents().associateBy { it.getString("event_name") }
        assertEquals("app_link", byName.getValue("app_first_open").props().getString("attribution_source"))
        assertEquals("clk_3", byName.getValue("app_first_open").props().getString("fr_click"))
        assertEquals("clk_3", byName.getValue("deep_link_opened").props().getString("fr_click"))
    }

    @Test
    fun ozelSemaBaglantiKanitSayilmaz() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        transport.requests.clear()
        sdk.handleLink("myapp://open?fr_click=clk_4")
        worker.drain()
        sdk.flushNow()
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun olaySemayaUyarVeParmakIziAlaniTasimaz() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        transport.requests.clear()
        sdk.track("purchase", mapOf("amount" to 10.5, "bad key" to 1, "nan" to Double.NaN, "obj" to Any()))
        worker.drain()
        sdk.flushNow()
        val event = sentEvents().single()
        assertEquals("android", event.getString("platform"))
        assertEquals(1, event.getInt("schema_version"))
        assertEquals("feralin-android", event.getJSONObject("sdk").getString("name"))
        assertEquals(true, event.getJSONObject("consent").getBoolean("analytics"))
        assertEquals(setOf("amount"), event.props().keys().asSequence().toSet())
        val context = event.getJSONObject("context")
        assertEquals(setOf("locale", "timezone", "app"), context.keys().asSequence().toSet())
        val forbidden = listOf("ip", "gaid", "advertising_id", "android_id", "device_model", "screen")
        val body = transport.requests.single().body
        forbidden.forEach { assertFalse(it, body.contains("\"$it\"")) }
    }

    @Test
    fun sarmalayiciPlatformVeSdkAlaniniBelirler() {
        val wrapped = FeralinEngine(
            config = FeralinConfig("pk_test_unit", "https://collect.example.com", GRANTED, wrapper = SdkWrapper("@feralin/react-native", "9.9.9", "react_native")),
            storeProvider = { store },
            transport = transport,
            referrer = { it(null) },
            appContext = { AppContext("tr-TR", "Europe/Istanbul", "1.2.3", "42") },
            state = worker,
            net = worker,
            clock = { worker.now },
            random = Random(7),
        )
        wrapped.start()
        worker.drain()
        wrapped.flushNow()
        val request = transport.requests.single()
        val event = request.events.single()
        assertEquals("react_native", event.getString("platform"))
        assertEquals("@feralin/react-native", event.getJSONObject("sdk").getString("name"))
        assertEquals("9.9.9", event.getJSONObject("sdk").getString("version"))
        assertEquals("@feralin/react-native/9.9.9", request.headers["User-Agent"])
        assertEquals("@feralin/react-native", wrapped.status().sdk)
    }

    @Test
    fun gecersizSarmalayiciReddedilir() {
        val bad = FeralinConfig("pk_test_unit", "https://c.example", wrapper = SdkWrapper("x", "1", "uydurma"))
        assertNotNull(bad.validationError())
        assertNull(FeralinConfig("pk_test_unit", "https://c.example", wrapper = SdkWrapper("x", "1", "react_native")).validationError())
    }

    @Test
    fun anahtarYalnizBasliktaTasinir() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        val request = transport.requests.single()
        assertEquals("https://collect.example.com/v1/batch", request.url)
        assertEquals("pk_test_unit", request.headers["x-feralin-project-key"])
        assertFalse(request.url.contains("pk_test_unit"))
        assertFalse(request.body.contains("pk_test_unit"))
        assertEquals("feralin-android/${FeralinEngine.SDK_VERSION_FALLBACK}", request.headers["User-Agent"])
    }

    @Test
    fun idempotencyAnahtariTumKimliklerdenTuretilirVeYenidenDenemedeAyniKalir() {
        val sdk = engine(GRANTED)
        transport.responses.addLast(null)
        sdk.track("a", null)
        sdk.track("b", null)
        worker.drain()
        sdk.flushNow()
        sdk.flushNow()
        val (first, second) = transport.requests
        assertEquals(first.headers["Idempotency-Key"], second.headers["Idempotency-Key"])
        val ids = first.events.map { it.getString("event_id") }
        assertEquals(Idempotency.keyFor(ids), first.headers["Idempotency-Key"])
    }

    @Test
    fun reklamIzniYoksaReferrerOkunmazFrClickGitmez() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_secret&utm_source=ads")
        for (consent in listOf(GRANTED, GRANTED_NO_AD)) {
            transport.requests.clear()
            val sdk = engineWith(consent, MemoryEventStore())
            sdk.flushNow()
            val event = sentEvents().single()
            assertEquals("app_first_open", event.getString("event_name"))
            assertEquals("none", event.props().getString("attribution_source"))
            assertFalse(event.props().has("fr_click"))
            assertFalse(event.props().has("utm_source"))
            assertFalse(transport.requests.single().body.contains("clk_secret"))
        }
        assertEquals("referrer izinsiz hiç okunmaz", 0, referrerReads)
    }

    @Test
    fun consentAlaniYalnizVerildiyseGider() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        assertFalse(sentEvents().single().getJSONObject("consent").has("advertising"))
        assertNull(sdk.status().consent?.advertising)
        transport.requests.clear()
        sdk.setConsent(GRANTED_NO_AD)
        sdk.track("a", null)
        worker.drain()
        sdk.flushNow()
        assertEquals(false, sentEvents().single().getJSONObject("consent").getBoolean("advertising"))
        assertEquals(false, sdk.status().consent?.advertising)
    }

    @Test
    fun reklamIzniVarsaFrClickVeConsentBirlikteGider() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_ok")
        val sdk = engine(GRANTED_AD)
        sdk.flushNow()
        val event = sentEvents().single()
        assertEquals("clk_ok", event.props().getString("fr_click"))
        assertEquals(true, event.getJSONObject("consent").getBoolean("advertising"))
    }

    @Test
    fun izinSonradanGelirseReferrerOZamanOkunurVeBirKezGider() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_later&utm_source=ads&gclid=x")
        val sdk = engine(GRANTED)
        sdk.flushNow()
        assertEquals(0, referrerReads)
        val firstOpen = sentEvents().single()
        assertEquals("none", firstOpen.props().getString("attribution_source"))
        val firstOpenAt = firstOpen.getString("occurred_at")
        transport.requests.clear()

        // İzin ilk açılıştan çok sonra gelir: olay zamanı izin anıdır, first_open_at ilk açılışı korur.
        worker.advance(3 * 24 * 3_600_000L)
        sdk.setConsent(GRANTED_AD)
        worker.drain()
        sdk.flushNow()
        assertEquals(1, referrerReads)
        val event = sentEvents().single()
        assertEquals("sunucu kurulum başına tek app_first_open kararı verir", "deep_link_opened", event.getString("event_name"))
        assertEquals("play_install_referrer", event.props().getString("attribution_source"))
        assertEquals("clk_later", event.props().getString("fr_click"))
        assertEquals(true, event.props().getBoolean("consent_followup"))
        assertFalse(transport.requests.single().body.contains("gclid"))
        assertEquals("ilk açılış zamanı olayda taşınır", firstOpenAt, event.props().getString("first_open_at"))

        // Ret-onay döngüsü ve yeni süreç ikinci kez üretmez.
        transport.requests.clear()
        sdk.setConsent(GRANTED_NO_AD)
        worker.drain()
        sdk.setConsent(GRANTED_AD)
        worker.drain()
        engine(GRANTED_AD)
        worker.drain()
        assertEquals(1, referrerReads)
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun sonradanGelenIzindeOrganikReferrerOlayUretmez() {
        referrerResult = AttributionParams.parseQuery("utm_source=google-play&utm_medium=organic")
        val sdk = engine(GRANTED)
        sdk.flushNow()
        transport.requests.clear()
        sdk.setConsent(GRANTED_AD)
        worker.drain()
        sdk.flushNow()
        assertTrue(transport.requests.isEmpty())
        assertNotNull(store.get(FeralinEngine.KEY_REFERRER_CHECKED))
    }

    @Test
    fun izinsizBaglantiKanitsizGiderIzinGelinceIsaretliOlayla() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        transport.requests.clear()
        sdk.handleLink("https://go.example.com/o/x?fr_click=clk_link&utm_campaign=yaz")
        worker.drain()
        sdk.flushNow()
        val plain = sentEvents().single()
        assertEquals("deep_link_opened", plain.getString("event_name"))
        assertEquals("none", plain.props().getString("attribution_source"))
        assertFalse(plain.props().has("fr_click"))
        assertFalse(plain.props().has("utm_campaign"))
        assertEquals("https://go.example.com/o/x", plain.getJSONObject("context").getString("page_url"))
        transport.requests.clear()

        sdk.setConsent(GRANTED_AD)
        worker.drain()
        sdk.flushNow()
        val followUp = sentEvents().first { it.props().has("fr_click") }
        assertEquals("deep_link_opened", followUp.getString("event_name"))
        assertEquals("app_link", followUp.props().getString("attribution_source"))
        assertEquals("clk_link", followUp.props().getString("fr_click"))
        assertEquals(true, followUp.props().getBoolean("consent_followup"))
    }

    @Test
    fun acikRetteBaglantiKanitiSaklanmaz() {
        val sdk = engine(GRANTED_NO_AD)
        sdk.flushNow()
        transport.requests.clear()
        sdk.handleLink("https://go.example.com/o/x?fr_click=clk_link")
        worker.drain()
        sdk.flushNow()
        transport.requests.clear()
        sdk.setConsent(GRANTED_AD)
        worker.drain()
        sdk.flushNow()
        assertFalse(transport.requests.joinToString { it.body }.contains("clk_link"))
    }

    @Test
    fun izinGeriCekilinceKuyruktakiBaglantiOlayiKanitsizGider() {
        val sdk = engine(GRANTED_AD)
        sdk.flushNow()
        transport.requests.clear()
        sdk.handleLink("https://go.example.com/o/x?fr_click=clk_queued&utm_campaign=yaz")
        sdk.track("plain", null)
        worker.drain()
        assertEquals(2, store.size())
        sdk.setConsent(GRANTED_NO_AD)
        worker.drain()
        assertEquals("açılış sayılmaya devam eder", 2, store.size())
        sdk.flushNow()
        assertEquals(listOf("deep_link_opened", "plain"), sentNames())
        val body = transport.requests.single().body
        assertFalse(body.contains("clk_queued"))
        assertFalse(body.contains("utm_campaign"))
        val event = sentEvents().first { it.getString("event_name") == "deep_link_opened" }
        assertEquals("none", event.props().getString("attribution_source"))
        assertEquals(false, event.getJSONObject("consent").getBoolean("advertising"))
    }

    @Test
    fun gonderilmemisIlkAcilisIzinGeriCekilinceKanitsizKalir() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_first&utm_source=ads")
        val sdk = engine(GRANTED_AD)
        worker.drain()
        assertEquals(1, store.size())
        val id = store.peek(1).single().eventId
        assertTrue(store.peek(1).single().payload.contains("clk_first"))

        sdk.setConsent(GRANTED_NO_AD)
        worker.drain()
        assertEquals("olay kaybolmaz", 1, store.size())
        assertEquals("olay kimliği korunur", id, store.peek(1).single().eventId)
        sdk.flushNow()
        val event = sentEvents().single()
        assertEquals("app_first_open", event.getString("event_name"))
        assertEquals(id, event.getString("event_id"))
        assertEquals("none", event.props().getString("attribution_source"))
        assertFalse(event.props().has("fr_click"))
        assertFalse(event.props().has("utm_source"))
        assertEquals(false, event.getJSONObject("consent").getBoolean("advertising"))
        assertFalse(transport.requests.single().body.contains("clk_first"))
        assertNotNull("işaret korunur, ikinci ilk açılış üretilmez", store.get(FeralinEngine.KEY_FIRST_OPEN))
    }

    @Test
    fun izinAlaniKalkincaBekleyenIlkAcilisKanitsizVeAlansizKalir() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_first")
        val sdk = engine(GRANTED_AD)
        worker.drain()
        sdk.setConsent(GRANTED)
        worker.drain()
        sdk.flushNow()
        val event = sentEvents().single()
        assertFalse(event.props().has("fr_click"))
        assertFalse("izin bildirilmediyse alan olayda bulunmaz", event.getJSONObject("consent").has("advertising"))
    }

    @Test
    fun yalnizKanitTasiyanFollowUpIzinGeriCekilinceAtilir() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_later")
        val sdk = engine(GRANTED)
        sdk.flushNow()
        transport.requests.clear()
        sdk.setConsent(GRANTED_AD)
        worker.drain()
        assertEquals(1, store.size())
        sdk.setConsent(GRANTED_NO_AD)
        worker.drain()
        assertEquals(0, store.size())
        sdk.flushNow()
        assertTrue(transport.requests.isEmpty())
    }

    @Test
    fun uygulamaOzelligiOlarakFrClickIzinsizGitmez() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        transport.requests.clear()
        assertNotNull(sdk.track("purchase", mapOf("fr_click" to "clk_manual", "amount" to 1)))
        worker.drain()
        sdk.flushNow()
        val event = sentEvents().single()
        assertFalse(event.props().has("fr_click"))
        assertEquals(1, event.props().getInt("amount"))
    }

    @Test
    fun yanitiKaybolanBatchAyniIcerikVeAnahtarlaYenidenDenenir() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        transport.requests.clear()
        sdk.track("a", null)
        worker.drain()
        // Sunucu yazdı ama yanıt yolda kayboldu: istemci sonucu bilmiyor.
        transport.responses.addLast(null)
        sdk.flushNow()
        // Araya yeni olay girse de ilk batch değişmez.
        sdk.track("b", null)
        worker.drain()
        sdk.flushNow()
        val (first, retry) = transport.requests
        assertEquals(first.body.substringAfter("\"events\":"), retry.body.substringAfter("\"events\":"))
        assertEquals(first.headers["Idempotency-Key"], retry.headers["Idempotency-Key"])
        // Sabit batch onaylanınca kalan olay kendi anahtarıyla gider.
        sdk.flushNow()
        val names = transport.requests.map { request -> request.events.map { it.getString("event_name") } }
        assertEquals(listOf(listOf("a"), listOf("a"), listOf("b")), names)
        assertEquals(0, store.size())
    }

    @Test
    fun retSonrasiSabitBatchGonderilmez() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        transport.requests.clear()
        sdk.track("a", null)
        worker.drain()
        transport.responses.addLast(null)
        sdk.flushNow()
        sdk.setConsent(DENIED)
        worker.drain()
        sdk.setConsent(GRANTED)
        worker.drain()
        sdk.flushNow()
        assertEquals("izin reddi sabit batch'i de siler", 1, transport.requests.size)
    }

    @Test
    fun durumKodlariWebSdkIleAyni() {
        val sdk = engine(GRANTED)
        transport.responses.addLast(TransportResponse(500, "", null))
        assertEquals(500, sdk.flushNow().status)
        assertEquals("5xx kuyrukta kalır", 1, store.size())

        transport.responses.addLast(TransportResponse(429, "", 3))
        assertEquals(429, sdk.flushNow().status)
        assertEquals("429 kuyrukta kalır", 1, store.size())

        worker.advance(4_000)
        transport.responses.addLast(TransportResponse(400, "{}", null))
        val rejected = sdk.flushNow()
        assertEquals(400, rejected.status)
        assertEquals(1, rejected.rejected)
        assertEquals("kalıcı ret tekrar denenmez", 0, store.size())
    }

    @Test
    fun kabulCevabiBatchKimligiVeSayilariTasir() {
        val sdk = engine(GRANTED)
        transport.responses.addLast(TransportResponse(202, """{"batch_id":"BATCH","accepted":0,"rejected":1}""", null))
        val result = sdk.flushNow()
        assertEquals("BATCH", result.batchId)
        assertEquals(1, result.rejected)
        assertEquals(0, store.size())
    }

    @Test
    fun cevrimdisiKuyrukAgGelinceBosalir() {
        val sdk = engine(GRANTED)
        sdk.onForeground()
        transport.responses.addLast(null)
        worker.drain()
        assertEquals(1, store.size())
        assertEquals(1, transport.requests.size)
        assertEquals("geri çekilme zamanlandı", 1, worker.pendingDelays().size)
        sdk.onNetworkAvailable()
        worker.drain()
        assertEquals(0, store.size())
        assertEquals(2, transport.requests.size)
    }

    @Test
    fun geriCekilmeUstelVeUstSinirli() {
        val sdk = engine(GRANTED)
        sdk.onForeground()
        repeat(30) { transport.responses.addLast(TransportResponse(503, "", null)) }
        worker.drain()
        val delays = ArrayList<Long>()
        repeat(12) {
            val delay = worker.pendingDelays().single()
            delays.add(delay)
            worker.advance(delay)
        }
        assertTrue("ilk bekleyiş 2,5-5 sn", delays[0] in 2_500L..5_000L)
        assertTrue("ikinci bekleyiş 5-10 sn", delays[1] in 5_000L..10_000L)
        assertTrue("üçüncü bekleyiş 10-20 sn", delays[2] in 10_000L..20_000L)
        assertTrue("üst sınır 15 dk", delays.all { it <= 15L * 60_000L })
        assertTrue("üst sınıra yaklaşır", delays.last() >= 7L * 60_000L)
    }

    @Test
    fun retryAfterAgGelseBileKorunur() {
        val sdk = engine(GRANTED)
        sdk.onForeground()
        transport.responses.addLast(TransportResponse(429, "", 120))
        worker.drain()
        assertEquals(1, transport.requests.size)
        sdk.onNetworkAvailable()
        worker.drain()
        assertEquals("Retry-After dolmadan istek yok", 1, transport.requests.size)
        worker.advance(121_000)
        assertEquals(2, transport.requests.size)
    }

    @Test
    fun arkaPlandaZamanlayiciKalmaz() {
        val sdk = engine(GRANTED)
        sdk.onForeground()
        transport.responses.addLast(null)
        worker.drain()
        assertEquals(1, worker.pendingDelays().size)
        sdk.onBackground()
        worker.drain()
        assertTrue("cihaz arka planda uyandırılmaz", worker.pendingDelays().isEmpty())
        worker.advance(3_600_000)
        val before = transport.requests.size
        sdk.onForeground()
        worker.drain()
        assertEquals("ön plana dönünce kuyruk boşalır", before + 1, transport.requests.size)
        assertEquals(0, store.size())
    }

    @Test
    fun kuyrukBosykenZamanlayiciKurulmaz() {
        val sdk = engine(GRANTED)
        sdk.onForeground()
        worker.drain()
        assertEquals(0, store.size())
        assertTrue(worker.pendingDelays().isEmpty())
    }

    @Test
    fun onPlandakiOlayAralikSonundaGonderilir() {
        val sdk = engine(GRANTED)
        sdk.onForeground()
        worker.drain()
        transport.requests.clear()
        sdk.track("a", null)
        worker.drain()
        assertTrue(transport.requests.isEmpty())
        assertEquals(listOf(15_000L), worker.pendingDelays())
        worker.advance(15_000)
        assertEquals(1, transport.requests.size)
    }

    @Test
    fun oturumZamanAsimindaYenilenirKisaGeciste() {
        val sdk = engine(GRANTED)
        sdk.onForeground()
        worker.drain()
        val first = sdk.status().sessionId
        sdk.onBackground()
        worker.drain()
        worker.advance(60_000)
        sdk.onForeground()
        worker.drain()
        assertEquals("kısa arka plan aynı oturum", first, sdk.status().sessionId)
        sdk.onBackground()
        worker.drain()
        worker.advance(30L * 60_000L)
        sdk.onForeground()
        worker.drain()
        assertNotEquals(first, sdk.status().sessionId)
    }

    @Test
    fun kuyrukUstSiniriEnEskiyiAtar() {
        val sdk = engine(GRANTED, queueLimit = 3)
        listOf("a", "b", "c", "d", "e").forEach { sdk.track(it, null) }
        worker.drain()
        assertEquals(3, store.size())
        assertEquals(3, sdk.status().queued)
    }

    @Test
    fun batchBoyutunaUlasincaGonderilirVeKalaniIzler() {
        val sdk = engine(GRANTED, batchSize = 2)
        sdk.flushNow()
        transport.requests.clear()
        repeat(5) { sdk.track("x", null) }
        worker.drain()
        assertTrue(transport.requests.all { it.events.size <= 2 })
        sdk.flushNow()
        assertEquals(0, store.size())
        assertEquals(5, sentEvents().size)
    }

    @Test
    fun buyukOlaylarBatchBoyutButcesiniAsmaz() {
        val sdk = engine(GRANTED, batchSize = 100)
        sdk.flushNow()
        transport.requests.clear()
        val big = "x".repeat(200 * 1024)
        repeat(6) { sdk.track("big", mapOf("v" to big)) }
        worker.drain()
        repeat(2) { sdk.flushNow() }
        assertTrue(transport.requests.all { it.body.length < 1024 * 1024 })
        assertTrue(transport.requests.size >= 2)
        assertEquals(0, store.size())
    }

    @Test
    fun boyutSiniriniAsanOlayAtilir() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        transport.requests.clear()
        sdk.track("huge", mapOf("v" to "x".repeat(300 * 1024)))
        worker.drain()
        assertEquals(0, store.size())
    }

    @Test
    fun gecersizOlayAdiUretilmez() {
        val sdk = engine(GRANTED)
        assertNull(sdk.track("Bad-Name", null))
        assertNull(sdk.track("a".repeat(101), null))
    }

    @Test
    fun resetKimligiYenilerKuyruguSilerIlkAcilisIsaretiniKorur() {
        val sdk = engine(GRANTED)
        sdk.flushNow()
        val before = sdk.status()
        sdk.identify("user_1")
        sdk.track("a", null)
        worker.drain()
        sdk.reset()
        worker.drain()
        val after = sdk.status()
        assertEquals(0, store.size())
        assertNull(after.userId)
        assertNotEquals(before.anonymousId, after.anonymousId)
        assertNotEquals(before.sessionId, after.sessionId)
        assertNotNull(store.get(FeralinEngine.KEY_FIRST_OPEN))
    }

    @Test
    fun taşımaHatasiUygulamayaSizmaz() {
        val failing = object : Transport {
            override fun post(url: String, headers: Map<String, String>, body: String): TransportResponse =
                throw IllegalStateException("beklenmeyen")
        }
        val sdk = FeralinEngine(
            config = FeralinConfig("pk_test_unit", "https://collect.example.com", GRANTED),
            storeProvider = { store },
            transport = failing,
            referrer = { it(null) },
            appContext = { AppContext(null, null, null, null) },
            state = worker,
            net = worker,
            clock = { worker.now },
        )
        sdk.start()
        worker.drain()
        val result = sdk.flushNow()
        assertEquals(0, result.status)
        assertEquals("olay kaybolmaz", 1, store.size())
    }

    private fun consume(sdk: FeralinEngine): DeferredDeepLink? {
        var result: DeferredDeepLink? = null
        sdk.consumeDeferredDeepLink { result = it }
        worker.drain()
        return result
    }

    @Test
    fun ertelenmisDerinBaglantiBirKezTeslimEdilirVeOlayaYazilmaz() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_1&fr_dl=%2Furun%2F42%3Frenk%3Dmavi")
        val sdk = engine(GRANTED_AD)
        worker.drain()
        assertEquals(DeferredDeepLink(DeferredDeepLinkStatus.DELIVERED, "/urun/42?renk=mavi"), consume(sdk))
        assertEquals(DeferredDeepLink(DeferredDeepLinkStatus.NONE), consume(sdk))
        for (event in store.peek(10)) {
            assertFalse("yol olaya girmemeli: ${event.payload}", event.payload.contains("urun/42") || event.payload.contains("fr_dl"))
        }
    }

    @Test
    fun ertelenmisDerinBaglantiSurecYenidenBaslasaDaKalir() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_1&fr_dl=%2Fa")
        engine(GRANTED_AD)
        worker.drain()
        val restarted = engine(GRANTED_AD)
        assertEquals("/a", consume(restarted)?.path)
        assertEquals("referrer kurulumda bir kez okunur", 1, referrerReads)
    }

    @Test
    fun yolYoksaNoneDoner() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_1")
        assertEquals(DeferredDeepLinkStatus.NONE, consume(engine(GRANTED_AD))?.status)
    }

    @Test
    fun reklamIzniYoksaReferrerOkunmazVeYolVerilmez() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_1&fr_dl=%2Fa")
        val sdk = engine(GRANTED_NO_AD)
        assertEquals(DeferredDeepLinkStatus.CONSENT_REQUIRED, consume(sdk)?.status)
        assertEquals(0, referrerReads)
        // İzin sonradan gelince referrer okunur, yol o zaman teslim edilir.
        sdk.setConsent(GRANTED_AD)
        worker.drain()
        assertEquals(DeferredDeepLink(DeferredDeepLinkStatus.DELIVERED, "/a"), consume(sdk))
    }

    @Test
    fun referrerOkunurkenSonucBeklenir() {
        holdReferrer = true
        referrerResult = null
        val sdk = engine(GRANTED_AD)
        worker.drain()
        var result: DeferredDeepLink? = null
        sdk.consumeDeferredDeepLink { result = it }
        worker.drain()
        assertNull("okuma bitmeden sonuç verilmez", result)
        heldReferrer!!.invoke(AttributionParams.parseQuery("fr_click=clk_1&fr_dl=%2Fbekle"))
        worker.drain()
        assertEquals(DeferredDeepLink(DeferredDeepLinkStatus.DELIVERED, "/bekle"), result)
    }

    @Test
    fun izinRetVeCikisTeslimEdilmemisYoluSiler() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_1&fr_dl=%2Fa")
        val denied = engine(GRANTED_AD)
        worker.drain()
        denied.setConsent(DENIED)
        worker.drain()
        assertNull(store.get(FeralinEngine.KEY_DEFERRED_DEEP_LINK))
        assertEquals(DeferredDeepLinkStatus.CONSENT_REQUIRED, consume(denied)?.status)

        val other = MemoryEventStore()
        val loggedOut = engineWith(GRANTED_AD, other)
        worker.drain()
        assertEquals("/a", other.get(FeralinEngine.KEY_DEFERRED_DEEP_LINK))
        loggedOut.reset()
        worker.drain()
        assertNull(other.get(FeralinEngine.KEY_DEFERRED_DEEP_LINK))
    }

    @Test
    fun geriCagriHatasiSdkyiDusurmez() {
        referrerResult = AttributionParams.parseQuery("fr_click=clk_1&fr_dl=%2Fa")
        val sdk = engine(GRANTED_AD)
        worker.drain()
        sdk.consumeDeferredDeepLink { throw IllegalStateException("uygulama hatası") }
        worker.drain()
        assertEquals(DeferredDeepLinkStatus.NONE, consume(sdk)?.status)
    }

    @Test
    fun okumaSurerkenCikisYoluBaskaKullaniciyaTasimaz() {
        holdReferrer = true
        val sdk = engine(GRANTED_AD)
        worker.drain()
        sdk.reset()
        worker.drain()
        heldReferrer!!.invoke(AttributionParams.parseQuery("fr_click=clk_1&fr_dl=%2Fa"))
        worker.drain()
        assertNull(store.get(FeralinEngine.KEY_DEFERRED_DEEP_LINK))
        assertEquals(DeferredDeepLinkStatus.NONE, consume(sdk)?.status)
    }
}
