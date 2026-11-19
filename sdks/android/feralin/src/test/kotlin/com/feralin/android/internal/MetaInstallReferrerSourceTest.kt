package com.feralin.android.internal

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MetaInstallReferrerSourceTest {
    private fun source(appId: String?, rows: Map<String, MetaReferrerRow?>, failing: Set<String> = emptySet()) =
        MetaInstallReferrerSource({ provider, _ ->
            if (provider in failing) throw SecurityException("izin yok")
            rows[provider]
        }, appId)

    @Test
    fun appIdYoksaOkunmaz() {
        val row = MetaReferrerRow("facebook", "{\"utm_source\":\"apps.facebook.com\"}", 1, 10L)
        assertNull(source(null, mapOf("facebook" to row)).read())
        assertNull(source(" ", mapOf("facebook" to row)).read())
    }

    @Test
    fun enYeniEtkilesimSecilirVeZarfOlusur() {
        val fb = MetaReferrerRow("facebook", "fb-referrer", 1, 100L)
        val ig = MetaReferrerRow("instagram", "ig-referrer", 0, 200L)
        val json = JSONObject(source("1234567890", mapOf("facebook" to fb, "instagram" to ig)).read()!!)
        assertEquals("ig-referrer", json.getString("r"))
        assertEquals(0, json.getInt("ct"))
        assertEquals(200L, json.getLong("ts"))
        assertEquals("instagram", json.getString("p"))
    }

    @Test
    fun saglayiciHatasiVeBosYanitKanitSayilmaz() {
        val lite = MetaReferrerRow("facebook_lite", "lite-referrer", null, null)
        val json = JSONObject(source("1234567890", mapOf("facebook_lite" to lite, "instagram" to MetaReferrerRow("instagram", "", 1, 5L)), failing = setOf("facebook")).read()!!)
        assertEquals("lite-referrer", json.getString("r"))
        assertEquals(false, json.has("ct"))
        assertNull(source("1234567890", emptyMap(), failing = setOf("facebook", "instagram", "facebook_lite")).read())
    }

    @Test
    fun asiriUzunReferrerAtilir() {
        assertNull(MetaInstallReferrerSource.envelope(MetaReferrerRow("facebook", "a".repeat(7_001), 1, 1L)))
    }
}
