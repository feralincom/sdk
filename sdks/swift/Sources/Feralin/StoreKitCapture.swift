// StoreKit 2 köprüsü: doğrulanmış işlemi platformdan bağımsız görüntüye (`StoreKitTransactionSnapshot`) çevirir; karar ve olay
// `Revenue.swift` içindedir (Linux'ta test edilir). Bu dosya yalnız Apple platformlarında derlenir. İmzalar developer.apple.com
// belgesinden okundu (20 Kasım 2026): `Transaction.updates` (iOS 15), `Transaction.price` (iOS 15, back-deployed), `Transaction.currency`
// ve `Transaction.environment` (iOS 16). SDK işlemi `finish()` ETMEZ: içeriği teslim edip işlemi bitirmek uygulamanındır.
#if canImport(StoreKit)
import Foundation
import StoreKit

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
extension FeralinClient {
    /// `Transaction.updates` dinleyicisini başlatır (bir kez; `close()` durdurur). Apple: dinleyici uygulama açılır açılmaz kurulmalıdır,
    /// bitmemiş işlemler açılıştan hemen sonra bir kez bildirilir. Uygulama dışı satın alma, aile onayı (Ask to Buy), teklif kodu, başka
    /// cihazdaki satın alma ve yenilemeler bu akışla gelir. Aynı cihazda `product.purchase()` dönen işlem için `trackStoreKitPurchase` çağırın.
    public func startStoreKitTransactionCapture() {
        guard storeKitListener == nil, !isClosed else { return }
        storeKitListener = Task.detached(priority: .background) { [weak self] in
            for await verification in Transaction.updates {
                guard let self else { return }
                _ = try? await self.trackStoreKitTransaction(verification)
            }
        }
    }

    public func stopStoreKitTransactionCapture() {
        storeKitListener?.cancel()
        storeKitListener = nil
    }

    /// `product.purchase()` sonucunu gelir olayına çevirir. Yalnız `.success` ve doğrulanmış işlem olay üretir.
    @discardableResult
    public func trackStoreKitPurchase(_ result: Product.PurchaseResult, product: Product? = nil) async throws -> StoreKitCaptureOutcome {
        switch result {
        case .success(let verification):
            return try await trackStoreKitTransaction(verification, product: product)
        case .userCancelled, .pending:
            return .notPurchased
        @unknown default:
            return .notPurchased
        }
    }

    /// Tek işlemi işler: yalnız `VerificationResult.verified` gönderilir, `jwsRepresentation` makbuz belirteci olur (sunucu Apple'a
    /// `transaction_id` ile sorar). İade ve iptal edilmiş, üst aboneliğe geçilmiş ve aile paylaşımıyla gelen işlem gelir sayılmaz.
    @discardableResult
    public func trackStoreKitTransaction(_ verification: VerificationResult<Transaction>, product: Product? = nil) async throws -> StoreKitCaptureOutcome {
        if isClosed { throw FeralinError.clientClosed }
        guard case .verified(let transaction) = verification else { return .unverified }
        let snapshot = await FeralinStoreKit.snapshot(transaction, jws: verification.jwsRepresentation, product: product)
        return try recordStoreKitTransaction(snapshot)
    }
}

@available(iOS 15.0, macOS 12.0, tvOS 15.0, watchOS 8.0, *)
enum FeralinStoreKit {
    static func kind(_ type: Product.ProductType) -> StoreKitProductKind {
        switch type {
        case .consumable: return .consumable
        case .nonConsumable: return .nonConsumable
        case .autoRenewable: return .autoRenewable
        case .nonRenewable: return .nonRenewable
        default: return .unknown
        }
    }

    /// Tutar önce işlemin kendisinden okunur (teklif ve indirim yansır); iOS 16 öncesinde para birimi, işlemde fiyat yoksa tutar
    /// ürün kataloğundan (`Product.price`, `priceFormatStyle.currencyCode`) tamamlanır.
    static func snapshot(_ transaction: Transaction, jws: String, product: Product?) async -> StoreKitTransactionSnapshot {
        var price: Decimal? = transaction.price
        var currency: String?
        var environment: String?
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, watchOS 9.0, *) {
            currency = transaction.currency?.identifier
            environment = transaction.environment.rawValue
        }
        if price == nil || currency == nil {
            var resolved = product
            if resolved == nil { resolved = try? await Product.products(for: [transaction.productID]).first }
            if let resolved {
                if currency == nil { currency = resolved.priceFormatStyle.currencyCode }
                // Katalog fiyatı birim fiyattır; Apple işlem fiyatı tüketilebilir üründe adet toplamıdır.
                if price == nil { price = resolved.price * Decimal(max(1, transaction.purchasedQuantity)) }
            }
        }
        return StoreKitTransactionSnapshot(
            transactionID: transaction.id,
            originalTransactionID: transaction.originalID,
            productID: transaction.productID,
            kind: kind(transaction.productType),
            price: price,
            currency: currency,
            quantity: transaction.purchasedQuantity,
            revocationDate: transaction.revocationDate,
            isUpgraded: transaction.isUpgraded,
            familyShared: transaction.ownershipType == .familyShared,
            jws: jws,
            environment: environment
        )
    }
}
#endif
