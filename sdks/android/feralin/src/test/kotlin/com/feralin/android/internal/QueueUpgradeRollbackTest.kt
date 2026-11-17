package com.feralin.android.internal

import android.app.Application
import com.feralin.android.Consent
import com.feralin.android.FeralinConfig
import com.feralin.android.FlushResult
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import kotlin.random.Random

/**
 * Kuyruk biçimi geçişi ve geri dönüş (SDK-R09, `docs/sdk/upgrade-guide.md`). Disk gerçek SQLite (Robolectric); "uygulama yeniden
 * başlatma" depo bağlantısını kapatıp aynı dosyayı yeni motorla açmaktır. Şifreleme öncesi yapı, aynı motorun sarmalayıcısız
 * `SqliteEventStore` ile çalışmasıdır (12eeb60 öncesi `Feralin.kt` depoyu böyle kuruyordu). Keystore cihaz ister; aynı AES-GCM
 * bellek içi anahtarla koşar.
 */
@RunWith(RobolectricTestRunner::class)
class QueueUpgradeRollbackTest {
    private val app: Application = RuntimeEnvironment.getApplication()
    private val worker = ManualWorker()
    private val transport = FakeTransport()
    private val key: SecretKey = KeyGenerator.getInstance("AES").apply { init(256) }.generateKey()
    private val granted = Consent(analytics = true)
    private val grantedAd = Consent(analytics = true, advertising = true)

    private fun engine(store: EventStore, consent: Consent = granted): FeralinEngine {
        val created = FeralinEngine(
            config = FeralinConfig("pk_test_unit", "https://collect.example.com", consent),
            storeProvider = { store },
            transport = transport,
            referrer = { it(null) },
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

    private fun encrypted(disk: SqliteEventStore) = EncryptedEventStore(disk, AesGcmPayloadCipher(key))

    /** Diskteki ham satırlar (şifreli ya da düz), sarmalayıcı olmadan. */
    private fun rawRows(): List<StoredEvent> {
        val raw = SqliteEventStore(app)
        return raw.peek(1000).also { raw.close() }
    }

    /** 202 alan isteklerdeki olay kimlikleri; sunucunun kabul ettiği her şey. */
    private fun acceptedIds(statuses: List<Int>): List<String> =
        transport.requests.zip(statuses).filter { it.second == 202 }.flatMap { (request, _) -> request.events.map { it.getString("event_id") } }

    @Test
    fun duzKuyruktanSifreliyeGecisteOlayKaybolmazVeBirKezGider() {
        // Şifreleme öncesi yapı çevrimdışı üç olay biriktirir.
        val plainDisk = SqliteEventStore(app)
        val old = engine(plainDisk)
        val tracked = listOf("a", "b", "c").map { old.track("sepet_$it", mapOf("not" to "gizli-deger-$it"))!! }
        worker.drain()
        val pending = plainDisk.peek(1000).map { it.eventId }
        assertTrue(pending.containsAll(tracked))
        assertTrue(plainDisk.peek(1000).all { it.payload.startsWith("{") })
        val firstOpenMarker = plainDisk.get("first_open_event_id")
        plainDisk.close()

        // Şifreli sürüm aynı dosyayı açar; ilk gönderim 500 alır, hiçbir satır silinmez ve satırlar artık şifrelidir.
        val upgradedDisk = SqliteEventStore(app)
        val upgraded = engine(encrypted(upgradedDisk))
        transport.responses.addLast(TransportResponse(500, "", null))
        assertEquals(500, upgraded.flushNow().status)
        upgradedDisk.close()
        val rows = rawRows()
        assertTrue(rows.map { it.eventId }.containsAll(pending))
        assertTrue(rows.all { it.payload.startsWith(AesGcmPayloadCipher.PREFIX) })
        assertFalse(rows.any { it.payload.contains("gizli-deger") })

        // Uygulama yeniden başlar: aynı olaylar aynı kimlik ve aynı Idempotency-Key ile bir kez kabul edilir.
        val restartedDisk = SqliteEventStore(app)
        val restarted = engine(encrypted(restartedDisk))
        assertEquals(202, restarted.flushNow().status)
        val statuses = listOf(500, 202)
        val accepted = acceptedIds(statuses)
        for (id in pending) assertEquals("$id bir kez kabul edilmeli", 1, accepted.count { it == id })
        assertEquals(accepted.size, accepted.toSet().size)
        assertEquals(transport.requests[0].headers["Idempotency-Key"], transport.requests[1].headers["Idempotency-Key"])
        // İlk açılış işareti şifrelenmez ve korunur: yükseltme ikinci bir app_first_open üretmez.
        assertEquals(firstOpenMarker, restartedDisk.get("first_open_event_id"))
        // 500 alan deneme ve yeniden gönderim aynı olayı taşır; farklı kimlikli ikinci bir ilk açılış olayı yoktur.
        val firstOpens = transport.requests.flatMap { it.events }.filter { it.getString("event_name") == "app_first_open" }.map { it.getString("event_id") }.toSet()
        assertTrue(firstOpens.size <= 1)
        firstOpenMarker?.let { assertEquals(setOf(it), firstOpens) }
        assertEquals(0, restartedDisk.size())
        restartedDisk.close()

        // Bir sonraki açılışta gönderilecek bir şey kalmaz.
        val again = SqliteEventStore(app)
        engine(encrypted(again)).flushNow()
        assertEquals(2, transport.requests.size)
        again.close()
    }

    @Test
    fun ayniAnahtarlaSifreliSurumlerArasindaDonusteKuyrukKorunur() {
        // Şifreli bir sürüm olay biriktirir; aynı biçimi okuyan başka bir şifreli yapıya dönülür (anahtar Keystore'da kalır).
        val first = SqliteEventStore(app)
        val producer = engine(encrypted(first))
        val ids = listOf("x", "y").map { producer.track("seviye_$it", null)!! }
        worker.drain()
        first.close()
        val second = SqliteEventStore(app)
        val back = engine(encrypted(second))
        assertEquals(202, back.flushNow().status)
        val sent = transport.requests.flatMap { it.events }.map { it.getString("event_id") }
        for (id in ids) assertEquals(1, sent.count { it == id })
        assertEquals(0, second.size())
        second.close()
    }

    @Test
    fun sifresizYapiyaDonusteReklamIzniYoksaSifreliSatirAcilistaAtilirDuzOlayGider() {
        // Belgelenen kayıp: reklam izni açık değilken açılışta kuyruktaki atıf kanıtı ayıklanır; `enc1:` satırı JSON olarak
        // ayrıştırılamaz ve atılır, hiç gönderilmez. Şifresiz yapının kendi olayı etkilenmez.
        val encDisk = SqliteEventStore(app)
        val sealed = engine(encrypted(encDisk)).track("odeme", mapOf("not" to "gizli-deger"))!!
        worker.drain()
        encDisk.close()

        val downgradedDisk = SqliteEventStore(app)
        val downgraded = engine(downgradedDisk)
        assertFalse(downgradedDisk.peek(1000).any { it.eventId == sealed })
        val plain = downgraded.track("eski_surum_olayi", null)!!
        worker.drain()
        assertEquals(202, downgraded.flushNow().status)
        val sent = transport.requests.flatMap { it.events }.map { it.getString("event_id") }
        assertEquals(1, sent.count { it == plain })
        assertFalse(sent.contains(sealed))
        assertFalse(transport.requests.any { it.body.contains(AesGcmPayloadCipher.PREFIX) })
        downgradedDisk.close()

        // Yeniden şifreli sürüme çıkılır: atılan satır geri gelmez, gönderilen olay yinelenmez.
        val reupgradedDisk = SqliteEventStore(app)
        engine(encrypted(reupgradedDisk)).flushNow()
        val everSent = transport.requests.flatMap { it.events }.map { it.getString("event_id") }
        assertEquals(1, everSent.count { it == plain })
        assertFalse(everSent.contains(sealed))
        reupgradedDisk.close()
    }

    @Test
    fun sifresizYapiyaDonusteReklamIzniVarsaBatchReddedilirKayipOlurAmaCiftGonderilmez() {
        // Belgelenen kayıp: reklam izni açıkken `enc1:` satırı ayıklanmaz ve batch'e girer; gövde geçersiz JSON olur, toplayıcı 400
        // döner ve motor kalıcı ret olarak bütün batch'i siler (aynı batch'teki düz olay dahil). Satırlar silindiği için yeniden
        // şifreli sürüme çıkıldığında da tekrar gönderilmez.
        val encDisk = SqliteEventStore(app)
        val sealed = engine(encrypted(encDisk), grantedAd).track("odeme", mapOf("not" to "gizli-deger"))!!
        worker.drain()
        encDisk.close()

        val downgradedDisk = SqliteEventStore(app)
        val downgraded = engine(downgradedDisk, grantedAd)
        val plain = downgraded.track("eski_surum_olayi", null)!!
        worker.drain()
        transport.responses.addLast(TransportResponse(400, "", null))
        val result = downgraded.flushNow()
        assertEquals(400, result.status)
        val body = transport.requests.single().body
        assertTrue(body.contains(AesGcmPayloadCipher.PREFIX))
        assertFalse(body.contains("gizli-deger"))
        assertTrue(body.contains(plain))
        assertEquals(0, downgradedDisk.size())
        downgradedDisk.close()

        val reupgradedDisk = SqliteEventStore(app)
        engine(encrypted(reupgradedDisk), grantedAd).flushNow()
        val laterIds = transport.requests.drop(1).flatMap { it.events }.map { it.getString("event_id") }
        assertFalse(laterIds.contains(sealed))
        assertFalse(laterIds.contains(plain))
        assertNotNull(sealed)
        reupgradedDisk.close()
    }
}
