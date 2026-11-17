package com.feralin.android.internal

import com.feralin.android.FeralinConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ParsingTest {
    @Test
    fun referrerIzinListesiDisiniOkumaz() {
        val params = AttributionParams.parseQuery(
            "utm_source=google&utm_medium=cpc&utm_campaign=y%C4%B1l&utm_term=a+b&utm_content=c" +
                "&fr_click=clk-1_2.3~4&gclid=X&utm_foo=bar&email=a%40b.c",
        )
        assertEquals("clk-1_2.3~4", params.frClick)
        assertEquals(
            mapOf(
                "utm_source" to "google",
                "utm_medium" to "cpc",
                "utm_campaign" to "yıl",
                "utm_term" to "a b",
                "utm_content" to "c",
            ),
            params.utm,
        )
    }

    @Test
    fun cifteKodlanmisReferrerAyristirilir() {
        val params = AttributionParams.parseQuery("fr_click%3Dclk_1%26utm_source%3Dads")
        assertEquals("clk_1", params.frClick)
        assertEquals("ads", params.utm["utm_source"])
    }

    @Test
    fun bozukVeBosGirdilerGuvenli() {
        assertTrue(AttributionParams.parseQuery(null).isEmpty)
        assertTrue(AttributionParams.parseQuery("").isEmpty)
        assertTrue(AttributionParams.parseQuery("&&=&fr_click&utm_source=").isEmpty)
        assertTrue(AttributionParams.parseQuery("fr_click=%ZZ").isEmpty)
        assertNull("geçersiz karakter taşınmaz", AttributionParams.parseQuery("fr_click=a%20b%3Cscript").frClick)
        assertNull(AttributionParams.parseQuery("fr_click=" + "a".repeat(257)).frClick)
    }

    @Test
    fun utmDegeriKesilirIlkDegerGecerli() {
        val params = AttributionParams.parseQuery("utm_source=" + "a".repeat(300) + "&utm_source=b&fr_click=one&fr_click=two")
        assertEquals(256, params.utm.getValue("utm_source").length)
        assertEquals("one", params.frClick)
    }

    @Test
    fun organikVarsayilanTanınır() {
        assertTrue(AttributionParams.parseQuery("utm_source=google-play&utm_medium=organic").isPlayOrganicDefault)
        assertTrue(AttributionParams.parseQuery("utm_source=(not%20set)&utm_medium=(not%20set)").isPlayOrganicDefault)
        assertFalse(AttributionParams.parseQuery("utm_source=ads&utm_medium=cpc").isPlayOrganicDefault)
        assertFalse(
            "tıklama kimliği varsa organik sayılmaz",
            AttributionParams.parseQuery("fr_click=c1&utm_medium=organic").isPlayOrganicDefault,
        )
    }

    @Test
    fun derinBaglantiTemizlenir() {
        val link = DeepLink.parse("HTTPS://user:pw@go.example.com:8443/a/b?token=s&fr_click=c1#frag")
        assertNotNull(link)
        assertEquals("https://go.example.com:8443/a/b", link!!.cleanUrl)
        assertEquals("c1", link.params.frClick)
    }

    @Test
    fun derinBaglantiGecersizleri() {
        assertNull(DeepLink.parse(null))
        assertNull(DeepLink.parse("myapp://x?fr_click=1"))
        assertNull(DeepLink.parse("https://bad host/x"))
        assertNull(DeepLink.parse("https:///yalniz-yol"))
        assertNull(DeepLink.parse("https://e.com/" + "a".repeat(3000)))
    }

    @Test
    fun idempotencyWebSdkTestVektoruyleAyni() {
        // packages/sdk-web/src/index.ts idempotencyKeyFor ile Node üzerinde üretilen değer.
        val a = "01JZZZZZZZZZZZZZZZZZZZZZZZ"
        val b = "01ABCDEFGHJKMNPQRSTVWXYZ01"
        assertEquals("51f0149954ab02da-2", Idempotency.keyFor(listOf(a, b)))
        assertEquals("sıradan bağımsız", Idempotency.keyFor(listOf(b, a)), Idempotency.keyFor(listOf(a, b)))
    }

    @Test
    fun ulidBicimiVeMonotonluk() {
        val first = Ulid.next(1_700_000_000_000L)
        val second = Ulid.next(1_700_000_000_000L)
        assertTrue(Regex("^[0-9A-HJKMNP-TV-Z]{26}$").matches(first))
        assertEquals(first.take(10), second.take(10))
        assertTrue(second > first)
        // Crockford zaman önek kontrolü: Web SDK ile aynı kodlama.
        assertEquals("01HF7YAT00", first.take(10))
    }

    @Test
    fun yapilandirmaDogrulama() {
        assertNotNull(FeralinConfig("sk_live_x", "https://e.com").validationError())
        assertNotNull(FeralinConfig("", "https://e.com").validationError())
        assertNotNull(FeralinConfig("pk_test", "ftp://e.com").validationError())
        assertNull(FeralinConfig("pk_test", "https://e.com").validationError())
    }

    @Test
    fun ertelenmisYolIzinListesiKuraliylaOkunur() {
        assertEquals("/urun/42?renk=mavi", AttributionParams.parseQuery("fr_click=c&fr_dl=%2Furun%2F42%3Frenk%3Dmavi").deepLinkPath)
        // Şema, host, protokolsüz adres, üst dizin ve kontrol karakteri geçmez.
        for (bad in listOf("https%3A%2F%2Fkotu.example", "%2F%2Fkotu.example", "urun", "%2Fa%2F..%2Fb", "%2F..", "%2Fa%0Ab", "%2Fa%20b",
            "%2F%252e%252e%2Fadmin", "%2F%252F%252Fkotu.example", "%2F%255c%255ckotu", "%2Fa%250Ab", "%2Fa%25", "%2Fa%25ZZ")) {
            assertEquals(bad, null, AttributionParams.parseQuery("fr_click=c&fr_dl=$bad").deepLinkPath)
        }
        // Tıklama kimliği olmadan yol alınmaz; yol kanıt sayılmaz ve olaya yazılmaz.
        val withoutClick = AttributionParams.parseQuery("fr_dl=%2Fa")
        assertEquals(null, withoutClick.deepLinkPath)
        assertEquals(true, withoutClick.isEmpty)
        val target = LinkedHashMap<String, Any?>()
        AttributionParams.parseQuery("fr_click=c&fr_dl=%2Fa").writeTo(target)
        assertEquals(setOf("fr_click"), target.keys)
    }
}
