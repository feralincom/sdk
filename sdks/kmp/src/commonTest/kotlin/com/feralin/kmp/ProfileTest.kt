package com.feralin.kmp

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** UTP §8.2 kimlik yöntemleri: group, setUserProperties, setGlobalProperties (toplayıcı profile_filter.go ile aynı kurallar). */
class ProfileTest {
    @Test
    fun piiKeyRuleMatchesCollector() {
        val pii = listOf(
            "email", "userEmail", "contact_email_address", "phone_number", "phoneNumber", "userIP", "ipv4",
            "first_name", "lastName", "name", "username", "ad", "soyadi", "home_address", "tckn",
        )
        val safe = listOf("plan", "plan_name", "zip", "hotel_tier", "membership", "ad_network")
        pii.forEach { assertTrue(ProfileRules.isPiiLikeKey(it), it) }
        safe.forEach { assertFalse(ProfileRules.isPiiLikeKey(it), it) }
    }

    @Test
    fun userPropertiesDropPiiReservedAndOffContractValues() = runTest {
        val collector = FakeCollector()
        val client = FeralinClient(config(), collector)
        val event = assertNotNull(
            client.setUserProperties(
                mapOf(
                    "plan" to "pro", "tier" to 2, "beta" to true, "email" to "a@b.co", "verified" to true, "note" to "x".repeat(257),
                    "nested" to mapOf("a" to 1), "list" to listOf(1), "ratio" to Double.NaN, "contact" to "x@y.io", "bad-key" to 1,
                ),
                userId = "u_1",
            ),
        )
        val props = event.payload.getValue("properties").jsonObject
        assertEquals(setOf("plan", "tier", "beta"), props.keys)
        assertEquals("fr_user_properties", event.payload.getValue("event_name").jsonPrimitive.content)
        assertEquals("u_1", event.payload.getValue("user_id").jsonPrimitive.content)
        assertNull(client.setUserProperties(mapOf("email" to "x", "phone" to "1")))
        assertNull(client.setUserProperties(emptyMap()))
        client.flush()
        assertEquals(1, collector.request(0).events.size)
    }

    @Test
    fun fiftyPropertiesPerCall() {
        val client = FeralinClient(config(), FakeCollector())
        val event = assertNotNull(client.setUserProperties((0 until 70).associate { "k$it" to it }))
        assertEquals(MAX_PROFILE_PROPERTIES, event.payload.getValue("properties").jsonObject.size)
    }

    @Test
    fun invalidGroupIdProducesNoEvent() {
        val client = FeralinClient(config(), FakeCollector())
        listOf("", "   ", "ekip@acme.com", "a\u0001b", "g".repeat(129)).forEach { assertNull(client.group(it), it) }
        val event = assertNotNull(client.group("acme-team", mapOf("plan" to "team", "group_id" to "sahte", "owner_email" to "x", "seats" to 12)))
        val props = event.payload.getValue("properties").jsonObject
        assertEquals("acme-team", props.getValue("group_id").jsonPrimitive.content)
        assertEquals(12, props.getValue("seats").jsonPrimitive.int)
        assertFalse("owner_email" in props)
    }

    @Test
    fun globalsMergeEventWinsNullRemovesNotOnSystemEvents() {
        val client = FeralinClient(config(), FakeCollector())
        assertEquals(1, client.setGlobalProperties(mapOf("app_release" to "1.2.0", "region" to "eu", "email" to "x")))
        client.setGlobalProperties(mapOf("region" to null, "channel" to "app"))
        val plain = assertNotNull(client.track("checkout_started", mapOf("channel" to "promo"))).payload.getValue("properties").jsonObject
        assertEquals("1.2.0", plain.getValue("app_release").jsonPrimitive.content)
        assertEquals("promo", plain.getValue("channel").jsonPrimitive.content)
        assertFalse("region" in plain)
        val profile = assertNotNull(client.setUserProperties(mapOf("plan" to "pro"))).payload.getValue("properties").jsonObject
        assertEquals(setOf("plan"), profile.keys)
        val group = assertNotNull(client.group("acme")).payload.getValue("properties").jsonObject
        assertEquals(setOf("group_id"), group.keys)
        client.clearGlobalProperties()
        assertNull(assertNotNull(client.track("after_clear")).payload["properties"])
    }

    @Test
    fun globalTotalCappedAtFifty() {
        val client = FeralinClient(config(), FakeCollector())
        client.setGlobalProperties((0 until 40).associate { "a$it" to it })
        assertEquals(30, client.setGlobalProperties((0 until 40).associate { "b$it" to it }))
        val props = assertNotNull(client.track("page_view")).payload.getValue("properties").jsonObject
        assertEquals(MAX_PROFILE_PROPERTIES, props.size)
    }

    @Test
    fun lengthsCountCodePointsAndNullDeletesDoNotCountTowardLimit() {
        // 256 emoji = 512 UTF-16 birimi; Web/Node gibi kod noktası sayılır, değer geçer. 257 emoji düşer.
        val emoji = "😀"
        assertEquals(1, ProfileRules.sanitize(mapOf("mood" to emoji.repeat(256))).properties.size)
        assertEquals(1, ProfileRules.sanitize(mapOf("mood" to emoji.repeat(257))).dropped)
        assertTrue(ProfileRules.isValidGroupId(emoji.repeat(128)))
        assertFalse(ProfileRules.isValidGroupId(emoji.repeat(129)))
        val input = LinkedHashMap<String, Any?>()
        (0 until 10).forEach { input["gone$it"] = null }
        (0 until 50).forEach { input["k$it"] = it }
        val result = ProfileRules.sanitize(input, allowNull = true)
        assertEquals(0, result.dropped)
        assertEquals(60, result.properties.size)
    }
}
