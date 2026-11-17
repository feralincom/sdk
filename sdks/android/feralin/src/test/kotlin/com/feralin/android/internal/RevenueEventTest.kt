package com.feralin.android.internal

import com.feralin.android.PurchaseType
import com.feralin.android.Receipt
import com.feralin.android.RevenueInput
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Test

/** F5-E04-T01: trackRevenue sözleşmesi; verified düşer, sözleşme dışı girdi olay üretmez. */
class RevenueEventTest {
    @Test
    fun sozlesmeAlanlariKurulurVeVerifiedDuser() {
        val props = RevenueEvent.properties(
            RevenueInput(
                transactionId = "ord_1",
                amountMinor = 4999,
                currency = "TRY",
                productId = "pro",
                purchaseType = PurchaseType.SUBSCRIPTION_START,
                receipt = Receipt(Receipt.Provider.STRIPE, "tok_1"),
                properties = mapOf("verified" to true, "receipt_digest" to "x", "plan" to "pro"),
            ),
        )
        requireNotNull(props)
        assertEquals("ord_1", props["transaction_id"])
        assertEquals(4999L, props["amount_minor"])
        assertEquals("TRY", props["currency"])
        assertEquals(1, props["quantity"])
        assertEquals("subscription_start", props["purchase_type"])
        assertEquals("pro", props["product_id"])
        assertEquals("pro", props["plan"])
        assertEquals(mapOf("provider" to "stripe", "token" to "tok_1"), props["receipt"])
        assertFalse(props.containsKey("verified"))
        assertFalse(props.containsKey("receipt_digest"))
        // Sanitize sonrası da bütün sözleşme alanları kalır (olay gövdesine bu hâliyle yazılır).
        val clean = EventJson.sanitize(props)
        assertEquals(4999L, clean["amount_minor"])
        assertFalse(clean.containsKey("verified"))
    }

    @Test
    fun sozlesmeDisiGirdiOlayUretmez() {
        val bad = listOf(
            RevenueInput("", 1, "TRY"),
            RevenueInput("t", -1, "TRY"),
            RevenueInput("t", RevenueEvent.MAX_AMOUNT_MINOR + 1, "TRY"),
            RevenueInput("t", 1, "try"),
            RevenueInput("t", 1, "TRY", quantity = -1),
            RevenueInput("t", 1, "TRY", productId = ""),
            RevenueInput("t", 1, "TRY", receipt = Receipt(Receipt.Provider.APPLE, "")),
            RevenueInput("t", 1, "TRY", purchaseType = PurchaseType.SUBSCRIPTION_CANCEL),
        )
        for (input in bad) assertNull(input.toString(), RevenueEvent.properties(input))
    }
}
