package com.feralin.android.internal

import com.feralin.android.Consent
import com.feralin.android.FeralinConfig
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Kurulum kimliği → gerçek `services/saas-api` `POST /v1/projects/{id}/attribution/account-links` (şartname §31.2 yol 5, ADR-0007). SDK hesap
 * kimliği yazmaz: uygulama kimliği kendi sunucusuna iletir, müşteri sunucusu gizli anahtarla ucu çağırır; bu test o sunucunun yerine geçer.
 * Yalnız FERALIN_E2E_API_URL, FERALIN_E2E_SERVER_KEY, FERALIN_E2E_PROJECT_ID ve FERALIN_E2E_ACCOUNT_REF tanımlıysa koşar (betik
 * `scripts/e2e-account-link.mjs` web tarafının hesap kanıtını önce yazar); yoksa atlanır ve atlanma "doğrulandı" sayılmaz.
 */
class AccountLinkE2ETest {
    private val apiUrl = System.getenv("FERALIN_E2E_API_URL")
    private val serverKey = System.getenv("FERALIN_E2E_SERVER_KEY")
    private val projectId = System.getenv("FERALIN_E2E_PROJECT_ID")
    private val accountRef = System.getenv("FERALIN_E2E_ACCOUNT_REF")

    @Before
    fun requireApi() {
        assumeTrue("FERALIN_E2E_API_URL/SERVER_KEY/PROJECT_ID/ACCOUNT_REF tanımlı değil", listOf(apiUrl, serverKey, projectId, accountRef).all { !it.isNullOrBlank() })
    }

    private fun engine(consent: Consent?, store: EventStore): FeralinEngine = FeralinEngine(
        config = FeralinConfig(projectKey = "pk_test_account_link", collectUrl = "http://127.0.0.1:9", consent = consent),
        storeProvider = { store },
        transport = HttpUrlTransport(),
        referrer = { it(null) },
        appContext = { AppContext("tr-TR", "Europe/Istanbul", "0.1.0", "1") },
        state = ExecutorWorker("e2e-state", log = {}),
        net = ExecutorWorker("e2e-net", log = {}),
    ).also { it.start() }

    private fun FeralinEngine.installId(): String? {
        val done = CountDownLatch(1)
        var id: String? = null
        installIdentifier {
            id = it
            done.countDown()
        }
        done.await(5, TimeUnit.SECONDS)
        return id
    }

    /** Müşteri sunucusunun çağrısı: gizli anahtar yalnız bu süreçte, uygulama koduna girmez. */
    private fun link(subjectId: String, account: String): Pair<Int, JSONObject?> {
        val body = JSONObject()
            .put("surface", "app")
            .put("subject_id", subjectId)
            .put("account_ref", account)
            .put("platform", "android")
            .put("consent", true)
            .toString()
        val response = HttpUrlTransport().post(
            "${apiUrl!!.trimEnd('/')}/v1/projects/$projectId/attribution/account-links",
            mapOf("Content-Type" to "application/json", "Accept" to "application/json", "Authorization" to "Bearer $serverKey"),
            body,
        )
        return response.status to runCatching { JSONObject(response.body) }.getOrNull()
    }

    @Test
    fun sdkKurulumKimligiAyniHesaplaBaglanirVeKullaniciOnayliKararUretir() {
        val store = MemoryEventStore()
        val sdk = engine(Consent(analytics = true, advertising = true), store)
        val install = sdk.installId()
        assertNotNull("reklam ölçümü izniyle kurulum kimliği üretilir", install)
        val (status, body) = link(install!!, accountRef!!)
        assertEquals(body?.toString(), 200, status)
        assertEquals(true, body!!.getBoolean("linked"))
        val confirmation = body.getJSONObject("confirmation")
        assertEquals("confirmed", confirmation.getString("status"))
        assertEquals("user_confirmed", confirmation.getString("decision"))
        assertEquals("matched_first_open_not_store_download", confirmation.getString("meaning"))

        // Aynı kurulum yeniden giriş yapar: yeni karar açılmaz.
        val (_, again) = link(sdk.installId()!!, accountRef)
        assertEquals("already_confirmed", again!!.getJSONObject("confirmation").getString("status"))
    }

    @Test
    fun izinGeriCekilinceKimlikSilinirYeniKimlikBaskaHesaplaBaglanmaz() {
        val store = MemoryEventStore()
        val sdk = engine(Consent(analytics = true, advertising = true), store)
        val first = sdk.installId()!!
        sdk.setConsent(Consent(analytics = false))
        assertNull("izin yokken kimlik verilmez", sdk.installId())
        sdk.setConsent(Consent(analytics = true, advertising = true))
        val second = sdk.installId()!!
        assertNotEquals("geri çekilen kimlik yeniden kullanılmaz", first, second)
        // Web tarafında kanıtı olmayan hesap: bağ yok, karar yok.
        val (status, body) = link(second, "${accountRef}-baska")
        assertEquals(200, status)
        assertEquals(false, body!!.getBoolean("linked"))
    }
}
