import Foundation
import XCTest
@testable import Feralin

/// `feralin_purchase` sözleşmesi (F5-E04-T01): Android `RevenueEventTest` ile aynı kurallar, küçük birim çevrimi (sunucudaki
/// `currencyExponent` ile aynı), yinelenen gönderim engeli ve StoreKit 2 işlem eşlemesi (Apple köprüsü dışındaki saf katman).
final class RevenueTests: XCTestCase {
    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("feralin-revenue-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func snapshot(
        id: UInt64 = 2_000_000_123,
        original: UInt64 = 2_000_000_123,
        kind: StoreKitProductKind = .nonConsumable,
        price: Decimal? = Decimal(string: "49.99"),
        currency: String? = "TRY",
        quantity: Int = 1,
        revoked: Bool = false,
        upgraded: Bool = false,
        familyShared: Bool = false,
        jws: String? = "eyJhbGciOiJFUzI1NiJ9.payload.sig",
        environment: String? = "Sandbox"
    ) -> StoreKitTransactionSnapshot {
        StoreKitTransactionSnapshot(
            transactionID: id,
            originalTransactionID: original,
            productID: "pro_lifetime",
            kind: kind,
            price: price,
            currency: currency,
            quantity: quantity,
            revocationDate: revoked ? Date(timeIntervalSince1970: 1_800_000_000) : nil,
            isUpgraded: upgraded,
            familyShared: familyShared,
            jws: jws,
            environment: environment
        )
    }

    // MARK: Sözleşme

    func testContractFieldsAndVerifiedDropped() throws {
        let props = try XCTUnwrap(RevenueEvent.properties(RevenueInput(
            transactionID: "ord_1",
            amountMinor: 4999,
            currency: "TRY",
            productID: "pro",
            purchaseType: .subscriptionStart,
            receipt: PurchaseReceipt(provider: .stripe, token: "tok_1"),
            properties: ["verified": true, "receipt_digest": "x", "plan": "pro"]
        )))
        XCTAssertEqual(props["transaction_id"], .string("ord_1"))
        XCTAssertEqual(props["amount_minor"], .int(4999))
        XCTAssertEqual(props["currency"], .string("TRY"))
        XCTAssertEqual(props["quantity"], .int(1))
        XCTAssertEqual(props["purchase_type"], .string("subscription_start"))
        XCTAssertEqual(props["product_id"], .string("pro"))
        XCTAssertEqual(props["plan"], .string("pro"))
        XCTAssertEqual(props["receipt"], .object(["provider": .string("stripe"), "token": .string("tok_1")]))
        XCTAssertNil(props["verified"])
        XCTAssertNil(props["receipt_digest"])
    }

    func testOutOfContractInputProducesNoEvent() {
        let bad = [
            RevenueInput(transactionID: "", amountMinor: 1, currency: "TRY"),
            RevenueInput(transactionID: String(repeating: "t", count: 129), amountMinor: 1, currency: "TRY"),
            RevenueInput(transactionID: "t", amountMinor: -1, currency: "TRY"),
            RevenueInput(transactionID: "t", amountMinor: RevenueEvent.maxAmountMinor + 1, currency: "TRY"),
            RevenueInput(transactionID: "t", amountMinor: 1, currency: "try"),
            RevenueInput(transactionID: "t", amountMinor: 1, currency: "TR"),
            RevenueInput(transactionID: "t", amountMinor: 1, currency: "TRY", quantity: -1),
            RevenueInput(transactionID: "t", amountMinor: 1, currency: "TRY", quantity: 100_001),
            RevenueInput(transactionID: "t", amountMinor: 1, currency: "TRY", productID: ""),
            RevenueInput(transactionID: "t", amountMinor: 1, currency: "TRY", receipt: PurchaseReceipt(provider: .apple, token: "")),
            RevenueInput(transactionID: "t", amountMinor: 1, currency: "TRY", receipt: PurchaseReceipt(provider: .apple, token: String(repeating: "a", count: 8193))),
            RevenueInput(transactionID: "t", amountMinor: 1, currency: "TRY", purchaseType: .subscriptionCancel),
        ]
        for input in bad { XCTAssertNil(RevenueEvent.properties(input), "\(input)") }
        XCTAssertNotNil(RevenueEvent.properties(RevenueInput(transactionID: "t", amountMinor: 0, currency: "TRY", purchaseType: .subscriptionCancel)))
    }

    // MARK: Küçük birim

    func testMinorUnitsFollowServerExponentAndRounding() {
        XCTAssertEqual(MinorUnits.amountMinor(Decimal(string: "49.99")!, currency: "TRY"), 4999)
        XCTAssertEqual(MinorUnits.amountMinor(Decimal(string: "0.99")!, currency: "USD"), 99)
        XCTAssertEqual(MinorUnits.amountMinor(Decimal(120), currency: "JPY"), 120)
        XCTAssertEqual(MinorUnits.amountMinor(Decimal(string: "1.2345")!, currency: "KWD"), 1235)
        // Yarım değer yukarı (sunucudaki Math.round): 0,005 USD → 1 cent; 0,004 → 0.
        XCTAssertEqual(MinorUnits.amountMinor(Decimal(string: "0.005")!, currency: "USD"), 1)
        XCTAssertEqual(MinorUnits.amountMinor(Decimal(string: "0.004")!, currency: "USD"), 0)
        XCTAssertEqual(MinorUnits.amountMinor(Decimal(string: "149.5")!, currency: "KRW"), 150)
        XCTAssertEqual(MinorUnits.amountMinor(Decimal(0), currency: "EUR"), 0)
        XCTAssertEqual(MinorUnits.amountMinor(Decimal(string: "90071992547409.91")!, currency: "USD"), RevenueEvent.maxAmountMinor)
        XCTAssertNil(MinorUnits.amountMinor(Decimal(string: "90071992547409.92")!, currency: "USD"))
        XCTAssertNil(MinorUnits.amountMinor(Decimal(-1), currency: "USD"))
        XCTAssertNil(MinorUnits.amountMinor(Decimal.nan, currency: "USD"))
        XCTAssertNil(MinorUnits.amountMinor(Decimal(1), currency: "usd"))
        XCTAssertEqual(MinorUnits.exponent(for: "BHD"), 3)
        XCTAssertEqual(MinorUnits.exponent(for: "VND"), 0)
        XCTAssertEqual(MinorUnits.exponent(for: "TRY"), 2)
    }

    // MARK: İstemci

    func testTrackRevenueWithDecimalAmountSendsContractEvent() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport)
        let event = try await client.trackRevenue(
            amount: Decimal(string: "49.99")!, currency: "TRY", productID: "pro", transactionID: "2000000123",
            receipt: PurchaseReceipt(provider: .apple, token: "jws.token.sig")
        )
        XCTAssertEqual(event?.eventName, "feralin_purchase")
        _ = try await client.flush()
        let wire = try XCTUnwrap(try transport.events(0).first)
        XCTAssertEqual(wire["event_name"] as? String, "feralin_purchase")
        let props = try XCTUnwrap(wire["properties"] as? [String: Any])
        XCTAssertEqual(props["amount_minor"] as? Int, 4999)
        XCTAssertEqual(props["currency"] as? String, "TRY")
        XCTAssertEqual(props["transaction_id"] as? String, "2000000123")
        XCTAssertEqual(props["purchase_type"] as? String, "purchase")
        let receipt = try XCTUnwrap(props["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["provider"] as? String, "apple")
        XCTAssertEqual(receipt["token"] as? String, "jws.token.sig")
        XCTAssertNil(props["verified"])
        // Ham JSON'da tutar ondalıksız tam sayıdır (toplayıcı 4999.0'ı reddeder).
        let raw = String(decoding: transport.request(0).body, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"amount_minor\":4999"), raw)
    }

    func testSameTransactionIsNotSentTwice() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport)
        let first = try await client.trackRevenue(RevenueInput(transactionID: "t1", amountMinor: 100, currency: "USD"))
        let again = try await client.trackRevenue(RevenueInput(transactionID: "t1", amountMinor: 100, currency: "USD"))
        let other = try await client.trackRevenue(RevenueInput(transactionID: "t1", amountMinor: 0, currency: "USD", purchaseType: .subscriptionCancel))
        XCTAssertNotNil(first)
        XCTAssertNil(again)
        XCTAssertNotNil(other)
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 2)
    }

    func testInvalidOrUnconsentedRevenueIsNotRecorded() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport, consent: Consent(analytics: false))
        let none = try await client.trackRevenue(RevenueInput(transactionID: "t2", amountMinor: 100, currency: "USD"))
        XCTAssertNil(none)
        // İzin yokken gönderilmeyen işlem kayda geçmez: izin gelince gönderilebilir.
        await client.setConsent(Consent(analytics: true))
        let later = try await client.trackRevenue(RevenueInput(transactionID: "t2", amountMinor: 100, currency: "USD"))
        XCTAssertNotNil(later)
        let invalid = try await client.trackRevenue(amount: Decimal(-5), currency: "USD", transactionID: "t3")
        XCTAssertNil(invalid)
    }

    func testLedgerPersistsWithStorageAndClearsOnConsentWithdrawal() async throws {
        let directory = makeDirectory()
        let first = try makeClient(transport: FakeTransport(), storageDirectory: directory)
        _ = try await first.trackRevenue(RevenueInput(transactionID: "t9", amountMinor: 100, currency: "USD"))
        await first.close(timeout: 0)
        let ledgerPath = directory.appendingPathComponent(FeralinDiskStore.purchasesFileName).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: ledgerPath))

        // Yeniden başlatma: aynı işlem kayıttan tanınır.
        let second = try makeClient(transport: FakeTransport(), storageDirectory: directory)
        let duplicate = try await second.trackRevenue(RevenueInput(transactionID: "t9", amountMinor: 100, currency: "USD"))
        XCTAssertNil(duplicate)
        await second.setConsent(Consent(analytics: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledgerPath))
        await second.setConsent(Consent(analytics: true))
        let resent = try await second.trackRevenue(RevenueInput(transactionID: "t9", amountMinor: 100, currency: "USD"))
        XCTAssertNotNil(resent)
    }

    func testLedgerWithoutStorageLivesOnlyInProcess() async throws {
        let first = try makeClient(transport: FakeTransport())
        let sent = try await first.trackRevenue(RevenueInput(transactionID: "t5", amountMinor: 1, currency: "USD"))
        XCTAssertNotNil(sent)
        // Kuyruk bellekteyken kayıt da bellektedir: yeni süreç gönderir, sunucu transaction_id ile tekilleştirir.
        let second = try makeClient(transport: FakeTransport())
        let resent = try await second.trackRevenue(RevenueInput(transactionID: "t5", amountMinor: 1, currency: "USD"))
        XCTAssertNotNil(resent)
    }

    func testLedgerKeepsNewestKeysWithinLimit() {
        var ledger = PurchaseLedger()
        for index in 0..<(PurchaseLedger.limit + 10) { ledger.insert("k\(index)") }
        XCTAssertEqual(ledger.keys.count, PurchaseLedger.limit)
        XCTAssertFalse(ledger.contains("k0"))
        XCTAssertTrue(ledger.contains("k\(PurchaseLedger.limit + 9)"))
        XCTAssertFalse(ledger.insert("k\(PurchaseLedger.limit + 9)"))
        let restored = PurchaseLedger(keys: (0..<600).map { "r\($0)" })
        XCTAssertEqual(restored.keys.count, PurchaseLedger.limit)
        XCTAssertTrue(restored.contains("r599"))
    }

    // MARK: StoreKit eşlemesi

    func testStoreKitPurchaseMapsToContract() throws {
        guard case .track(let input) = StoreKitMapping.decide(snapshot()) else { return XCTFail("olay bekleniyordu") }
        XCTAssertEqual(input.transactionID, "2000000123")
        XCTAssertEqual(input.amountMinor, 4999)
        XCTAssertEqual(input.currency, "TRY")
        XCTAssertEqual(input.productID, "pro_lifetime")
        XCTAssertEqual(input.purchaseType, .purchase)
        XCTAssertEqual(input.receipt, PurchaseReceipt(provider: .apple, token: "eyJhbGciOiJFUzI1NiJ9.payload.sig"))
        XCTAssertEqual(input.properties?["original_transaction_id"], .string("2000000123"))
        XCTAssertEqual(input.properties?["store_environment"], .string("Sandbox"))
        XCTAssertEqual(input.properties?["product_kind"], .string("non_consumable"))
        let props = try XCTUnwrap(RevenueEvent.properties(input))
        XCTAssertEqual(props["receipt"], .object(["provider": .string("apple"), "token": .string("eyJhbGciOiJFUzI1NiJ9.payload.sig")]))
    }

    func testStoreKitSubscriptionStartAndRenew() {
        guard case .track(let start) = StoreKitMapping.decide(snapshot(id: 10, original: 10, kind: .autoRenewable)),
              case .track(let renew) = StoreKitMapping.decide(snapshot(id: 11, original: 10, kind: .autoRenewable)),
              case .track(let nonRenewing) = StoreKitMapping.decide(snapshot(id: 12, original: 9, kind: .nonRenewable)) else {
            return XCTFail("olay bekleniyordu")
        }
        XCTAssertEqual(start.purchaseType, .subscriptionStart)
        XCTAssertEqual(renew.purchaseType, .subscriptionRenew)
        XCTAssertEqual(renew.properties?["original_transaction_id"], .string("10"))
        XCTAssertEqual(nonRenewing.purchaseType, .purchase)
        // Ücretsiz deneme 0 tutarla aboneliği başlatır.
        guard case .track(let trial) = StoreKitMapping.decide(snapshot(id: 20, original: 20, kind: .autoRenewable, price: 0)) else { return XCTFail() }
        XCTAssertEqual(trial.amountMinor, 0)
    }

    func testStoreKitConsumableUsesTransactionTotal() {
        // Apple: tüketilebilir üründe işlem fiyatı adet toplamıdır; SDK yeniden çarpmaz.
        guard case .track(let input) = StoreKitMapping.decide(snapshot(kind: .consumable, price: Decimal(string: "2.97"), currency: "usd", quantity: 3)) else {
            return XCTFail("olay bekleniyordu")
        }
        XCTAssertEqual(input.amountMinor, 297)
        XCTAssertEqual(input.quantity, 3)
        XCTAssertEqual(input.currency, "USD")
    }

    func testStoreKitSkipsNonRevenueTransactions() {
        XCTAssertEqual(StoreKitMapping.decide(snapshot(revoked: true)), .skip(.revoked))
        XCTAssertEqual(StoreKitMapping.decide(snapshot(upgraded: true)), .skip(.upgraded))
        XCTAssertEqual(StoreKitMapping.decide(snapshot(familyShared: true)), .skip(.familyShared))
        XCTAssertEqual(StoreKitMapping.decide(snapshot(price: nil)), .skip(.missingPrice))
        XCTAssertEqual(StoreKitMapping.decide(snapshot(currency: nil)), .skip(.missingPrice))
        XCTAssertEqual(StoreKitMapping.decide(snapshot(currency: "TL")), .skip(.missingPrice))
    }

    func testStoreKitOversizedJwsIsNotSentAsReceipt() {
        guard case .track(let input) = StoreKitMapping.decide(snapshot(jws: String(repeating: "a", count: 8193), environment: nil)) else {
            return XCTFail("olay bekleniyordu")
        }
        XCTAssertNil(input.receipt)
        XCTAssertNil(input.properties?["store_environment"])
    }

    func testRecordStoreKitTransactionDeduplicates() async throws {
        let transport = FakeTransport()
        let client = try makeClient(transport: transport)
        let first = try await client.recordStoreKitTransaction(snapshot(id: 77, original: 77, kind: .autoRenewable))
        guard case .tracked(let event) = first else { return XCTFail("olay bekleniyordu: \(first)") }
        XCTAssertEqual(event.properties?["purchase_type"], .string("subscription_start"))
        let again = try await client.recordStoreKitTransaction(snapshot(id: 77, original: 77, kind: .autoRenewable))
        XCTAssertEqual(again, .duplicate)
        let revoked = try await client.recordStoreKitTransaction(snapshot(id: 78, revoked: true))
        XCTAssertEqual(revoked, .revoked)
        let queued = await client.queuedCount
        XCTAssertEqual(queued, 1)

        let silent = try makeClient(transport: FakeTransport(), consent: Consent(analytics: false))
        let notTracked = try await silent.recordStoreKitTransaction(snapshot(id: 79))
        XCTAssertEqual(notTracked, .notTracked)
    }
}
