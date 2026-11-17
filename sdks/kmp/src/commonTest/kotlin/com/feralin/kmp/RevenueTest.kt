package com.feralin.kmp

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long

/** `trackRevenue` sözleşmesi (Web `buildRevenueProperties` ile aynı kurallar). */
class RevenueTest {
    private val base = Revenue(transactionId = "GPA.1234", amountMinor = 4999, currency = "TRY")

    @Test
    fun validPurchaseBuildsContractAndDropsVerification() = runTest {
        val collector = FakeCollector()
        val client = FeralinClient(config(), collector)
        val event = assertNotNull(
            client.trackRevenue(
                base.copy(
                    productId = "pro_monthly",
                    quantity = 2,
                    purchaseType = PurchaseType.SUBSCRIPTION_START,
                    receipt = Receipt(ReceiptProvider.GOOGLE, "tok_abc"),
                    properties = mapOf("plan" to "pro", "verified" to true, "verification_source" to "client", "receipt_digest" to "x", "receipt_provider" to "apple"),
                ),
                userId = "u_1",
            ),
        )
        assertEquals("feralin_purchase", event.payload.getValue("event_name").jsonPrimitive.content)
        val props = event.payload.getValue("properties").jsonObject
        assertEquals(
            setOf("plan", "transaction_id", "amount_minor", "currency", "quantity", "purchase_type", "product_id", "receipt"),
            props.keys,
        )
        assertEquals(4999L, props.getValue("amount_minor").jsonPrimitive.long)
        assertEquals(2, props.getValue("quantity").jsonPrimitive.int)
        assertEquals("subscription_start", props.getValue("purchase_type").jsonPrimitive.content)
        val receipt = props.getValue("receipt").jsonObject
        assertEquals("google", receipt.getValue("provider").jsonPrimitive.content)
        assertEquals("tok_abc", receipt.getValue("token").jsonPrimitive.content)
        assertFalse("verified" in props)
        assertFalse("tok_abc" in Receipt(ReceiptProvider.GOOGLE, "tok_abc").toString())
        client.flush()
        assertEquals(1, collector.request(0).events.size)
    }

    @Test
    fun defaultsAreQuantityOneAndPurchase() {
        val props = assertNotNull(revenueProperties(base))
        assertEquals(1, props["quantity"])
        assertEquals("purchase", props["purchase_type"])
        assertFalse("product_id" in props)
        assertFalse("receipt" in props)
    }

    @Test
    fun invalidInputProducesNoEvent() {
        val client = FeralinClient(config(), FakeCollector())
        val invalid = listOf(
            base.copy(transactionId = ""),
            base.copy(transactionId = "t".repeat(129)),
            base.copy(amountMinor = -1),
            base.copy(amountMinor = MAX_AMOUNT_MINOR + 1),
            base.copy(currency = "try"),
            base.copy(currency = "TRYX"),
            base.copy(productId = ""),
            base.copy(productId = "p".repeat(129)),
            base.copy(quantity = -1),
            base.copy(quantity = 100_001),
            base.copy(purchaseType = PurchaseType.SUBSCRIPTION_CANCEL, amountMinor = 100),
            base.copy(receipt = Receipt(ReceiptProvider.APPLE, "")),
            base.copy(receipt = Receipt(ReceiptProvider.APPLE, "t".repeat(8193))),
        )
        invalid.forEach { assertNull(client.trackRevenue(it), it.toString()) }
        assertEquals(0, client.queued)
    }

    @Test
    fun boundariesAreAccepted() {
        assertNotNull(revenueProperties(base.copy(amountMinor = 0, quantity = 0)))
        assertNotNull(revenueProperties(base.copy(amountMinor = MAX_AMOUNT_MINOR, quantity = 100_000)))
        assertNotNull(revenueProperties(base.copy(purchaseType = PurchaseType.SUBSCRIPTION_CANCEL, amountMinor = 0)))
        assertNotNull(revenueProperties(base.copy(transactionId = "t".repeat(128), receipt = Receipt(ReceiptProvider.STRIPE, "t".repeat(8192)))))
    }

    @Test
    fun noConsentNoEvent() {
        val client = FeralinClient(config(consent = Consent()), FakeCollector())
        assertNull(client.trackRevenue(base))
    }
}
