import Foundation

// Satın alma geliri (`feralin_purchase`, F5-E04-T01). Kurallar Android (`RevenueEvent.kt`), Flutter ve Web SDK'larıyla birebir aynıdır;
// kaynak `packages/schemas/utp/v1/event.schema.json` ve sunucudaki `revenue-event.ts`. İstemci beyanıdır: `verified` hiçbir zaman
// gönderilmez; satır yalnız sunucu tarafı makbuz doğrulayıcısı (Apple App Store Server API) onaylarsa REAL_VERIFIED olur.
// Bu dosya platformdan bağımsızdır (Linux'ta derlenir ve test edilir); StoreKit 2 köprüsü `StoreKitCapture.swift` içindedir.

/// Satın alma türü (`purchase_type`).
public enum PurchaseType: String, Sendable, CaseIterable {
    case purchase
    case subscriptionStart = "subscription_start"
    case subscriptionRenew = "subscription_renew"
    /// Abonelik iptali para taşımaz: tutar 0 olmalıdır.
    case subscriptionCancel = "subscription_cancel"
}

/// İsteğe bağlı ham makbuz. Toplayıcı belirteci olay deposuna yazmaz: yalnız sağlayıcı adını (`receipt_provider`) ve belirtecin
/// SHA-256 özetini (`receipt_digest`) saklar. Sunucu yalnız `receipt_provider` varsa sağlayıcıya sorar; Apple'da sorgu `transaction_id` iledir.
public struct PurchaseReceipt: Equatable, Sendable {
    public enum Provider: String, Sendable {
        case apple
        case google
        case stripe
    }

    public var provider: Provider
    /// Makbuz ya da satın alma belirteci (en çok 8192 karakter). StoreKit 2'de `VerificationResult.jwsRepresentation`.
    public var token: String

    public init(provider: Provider, token: String) {
        self.provider = provider
        self.token = token
    }
}

/// `trackRevenue` girdisi. Tutar küçük birimde tam sayıdır (kuruş, cent): 49,99 TRY için 4999. `quantity` ile çarpılmaz, satır toplamıdır.
public struct RevenueInput: Equatable, Sendable {
    /// Mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz (1-128 karakter); sunucu aynı işlemi ikinci kez saymaz.
    /// StoreKit 2'de `String(transaction.id)`: Apple doğrulaması bu kimlikle yapılır.
    public var transactionID: String
    public var amountMinor: Int64
    /// ISO 4217, üç büyük harf.
    public var currency: String
    public var productID: String?
    public var quantity: Int
    public var purchaseType: PurchaseType
    public var receipt: PurchaseReceipt?
    /// Ek özellikler; `verified` ve türevleri düşürülür.
    public var properties: [String: FeralinValue]?

    public init(
        transactionID: String,
        amountMinor: Int64,
        currency: String,
        productID: String? = nil,
        quantity: Int = 1,
        purchaseType: PurchaseType = .purchase,
        receipt: PurchaseReceipt? = nil,
        properties: [String: FeralinValue]? = nil
    ) {
        self.transactionID = transactionID
        self.amountMinor = amountMinor
        self.currency = currency
        self.productID = productID
        self.quantity = quantity
        self.purchaseType = purchaseType
        self.receipt = receipt
        self.properties = properties
    }
}

/// Gelir olayı gövdesi; saf işlevlerdir ve testlerde doğrudan sınanır.
enum RevenueEvent {
    static let name = "feralin_purchase"
    /// JS güvenli tam sayı üst sınırı; sunucu bigint taşır.
    static let maxAmountMinor: Int64 = 9_007_199_254_740_991
    static let maxQuantity = 100_000
    static let maxReceiptToken = 8192
    // İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, toplayıcı da düşürür.
    static let reservedKeys = ["verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"]

    /// Sözleşme dışı girdide `nil` (olay üretilmez).
    static func properties(_ input: RevenueInput) -> [String: FeralinValue]? {
        guard !input.transactionID.isEmpty, input.transactionID.unicodeScalars.count <= 128 else { return nil }
        guard input.amountMinor >= 0, input.amountMinor <= maxAmountMinor else { return nil }
        guard isCurrency(input.currency) else { return nil }
        if let productID = input.productID, productID.isEmpty || productID.unicodeScalars.count > 128 { return nil }
        guard input.quantity >= 0, input.quantity <= maxQuantity else { return nil }
        // Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
        if input.purchaseType == .subscriptionCancel, input.amountMinor != 0 { return nil }
        if let receipt = input.receipt, receipt.token.isEmpty || receipt.token.unicodeScalars.count > maxReceiptToken { return nil }
        var out = input.properties ?? [:]
        for key in reservedKeys { out.removeValue(forKey: key) }
        out["transaction_id"] = .string(input.transactionID)
        out["amount_minor"] = .int(input.amountMinor)
        out["currency"] = .string(input.currency)
        out["quantity"] = .int(Int64(input.quantity))
        out["purchase_type"] = .string(input.purchaseType.rawValue)
        if let productID = input.productID { out["product_id"] = .string(productID) }
        if let receipt = input.receipt {
            out["receipt"] = .object(["provider": .string(receipt.provider.rawValue), "token": .string(receipt.token)])
        }
        return out
    }

    static func isCurrency(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        return scalars.count == 3 && scalars.allSatisfy { $0.value >= 0x41 && $0.value <= 0x5A }
    }

    /// Yinelenen gönderim anahtarı: aynı işlem aynı türle ikinci kez gönderilmez.
    static func ledgerKey(transactionID: String, purchaseType: PurchaseType) -> String {
        "\(purchaseType.rawValue):\(transactionID)"
    }
}

/// Ondalık tutarı küçük birime çevirir. Üs listesi sunucudaki `currencyExponent` (apple-receipt-validator.ts) ile aynıdır: sunucu
/// Apple'ın bildirdiği fiyatı aynı kuralla küçük birime çevirip `amount_minor` ile karşılaştırır.
public enum MinorUnits {
    private static let zeroDecimal: Set<String> = ["JPY", "KRW", "VND", "CLP", "ISK", "UGX", "XAF", "XOF", "PYG", "RWF"]
    private static let threeDecimal: Set<String> = ["BHD", "JOD", "KWD", "OMR", "TND"]

    /// ISO 4217 küçük birim üssü; listede olmayan para birimi iki ondalıklıdır.
    public static func exponent(for currency: String) -> Int {
        if zeroDecimal.contains(currency) { return 0 }
        if threeDecimal.contains(currency) { return 3 }
        return 2
    }

    /// `Decimal` tutarı (ör. StoreKit `Product.price` ya da `Transaction.price`) küçük birimde tam sayıya çevirir; yarım değer yukarı
    /// yuvarlanır (sunucudaki `Math.round` ile aynı, tutar negatif olamaz). Negatif, sayı olmayan ya da sınır dışı tutarda `nil`.
    public static func amountMinor(_ amount: Decimal, currency: String) -> Int64? {
        guard !amount.isNaN, amount >= 0, RevenueEvent.isCurrency(currency) else { return nil }
        var scaled = amount
        for _ in 0..<exponent(for: currency) { scaled *= 10 }
        var source = scaled
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard rounded <= Decimal(RevenueEvent.maxAmountMinor) else { return nil }
        // Dönüşüm metin üzerinden: büyük tutarda kayan noktaya düşüp hassasiyet kaybetmesin.
        return Int64(NSDecimalNumber(decimal: rounded).stringValue)
    }
}

/// Gönderilmiş gelir işlemlerinin küçük kaydı (en çok `limit` anahtar, en eskisi önce düşer). `storageDirectory` verilirse diske yazılır;
/// StoreKit her açılışta bitmemiş işlemleri yeniden bildirse de aynı işlem ikinci kez kuyruğa girmez. Sunucu ayrıca `transaction_id` ile tekilleştirir.
struct PurchaseLedger: Equatable, Sendable {
    static let limit = 512
    private(set) var keys: [String]
    private var index: Set<String>

    init(keys: [String] = []) {
        let kept = Array(keys.suffix(Self.limit))
        self.keys = kept
        self.index = Set(kept)
    }

    func contains(_ key: String) -> Bool { index.contains(key) }

    /// Yeni anahtar eklendiyse true.
    @discardableResult
    mutating func insert(_ key: String) -> Bool {
        guard !index.contains(key) else { return false }
        keys.append(key)
        index.insert(key)
        if keys.count > Self.limit {
            let removed = keys.removeFirst()
            index.remove(removed)
        }
        return true
    }

    mutating func removeAll() {
        keys.removeAll()
        index.removeAll()
    }
}

// MARK: - StoreKit işlemi (platformdan bağımsız görüntü)

/// StoreKit ürün türü (`Product.ProductType`).
public enum StoreKitProductKind: String, Sendable {
    case consumable
    case nonConsumable = "non_consumable"
    case autoRenewable = "auto_renewable"
    case nonRenewable = "non_renewable"
    case unknown
}

/// Doğrulanmış StoreKit 2 işleminin gelir olayına gereken alanları. Apple köprüsü `Transaction` değerinden kurar; Linux'ta testler doğrudan kurar.
struct StoreKitTransactionSnapshot: Equatable, Sendable {
    var transactionID: UInt64
    var originalTransactionID: UInt64
    var productID: String
    var kind: StoreKitProductKind
    /// İşlemin kaydettiği tutar (para birimi cinsinden, ör. 49.99). Apple: tüketilebilir üründe adet toplamıdır, öteki türlerde ürün fiyatı.
    var price: Decimal?
    var currency: String?
    var quantity: Int
    var revocationDate: Date?
    var isUpgraded: Bool
    var familyShared: Bool
    /// `VerificationResult.jwsRepresentation`; makbuz belirteci olarak gönderilir.
    var jws: String?
    /// `AppStore.Environment` (Production, Sandbox, Xcode); iOS 16 öncesinde nil.
    var environment: String?
}

/// StoreKit işleminin sonucu. `tracked` dışındaki durumlarda olay üretilmez.
public enum StoreKitCaptureOutcome: Equatable, Sendable {
    case tracked(TrackedEvent)
    /// Aynı işlem bu kurulumda zaten gönderildi.
    case duplicate
    /// `VerificationResult.unverified`: Apple imzası doğrulanmadı, gelir yazılmaz.
    case unverified
    /// İade ya da hak iptali (`revocationDate`). Sunucu iadeyi istemci olayından değil App Store Server Notifications V2'den yazar.
    case revoked
    /// Daha üst bir aboneliğe geçilmiş eski işlem.
    case upgraded
    /// Aile paylaşımıyla gelen hak: ödemeyi bu kullanıcı yapmadı, gelir sayılmaz.
    case familyShared
    /// İşlemde fiyat ya da para birimi yok ve ürün bilgisi de alınamadı.
    case missingPrice
    /// Satın alma tamamlanmadı (`userCancelled`, `pending`).
    case notPurchased
    /// Analitik izni yok ya da girdi sözleşme dışı.
    case notTracked
}

enum StoreKitMapping {
    enum Decision: Equatable {
        case track(RevenueInput)
        case skip(StoreKitCaptureOutcome)
    }

    /// Doğrulanmış işlemi gelir girdisine çevirir. Abonelikte ilk işlem (`id == originalID`) `subscription_start`, sonrakiler
    /// `subscription_renew`; öteki türler `purchase`. Tutar işlemin kendi fiyatıdır (ürün kataloğu fiyatı değil): teklif ve
    /// indirim işlemde yansır, sunucu Apple'dan aynı işlemi okuyup karşılaştırır.
    static func decide(_ snapshot: StoreKitTransactionSnapshot) -> Decision {
        if snapshot.revocationDate != nil { return .skip(.revoked) }
        if snapshot.isUpgraded { return .skip(.upgraded) }
        if snapshot.familyShared { return .skip(.familyShared) }
        guard let price = snapshot.price, let currency = snapshot.currency?.uppercased(),
              let amount = MinorUnits.amountMinor(price, currency: currency) else { return .skip(.missingPrice) }
        let type: PurchaseType
        switch snapshot.kind {
        case .autoRenewable:
            type = snapshot.transactionID == snapshot.originalTransactionID ? .subscriptionStart : .subscriptionRenew
        case .consumable, .nonConsumable, .nonRenewable, .unknown:
            type = .purchase
        }
        var properties: [String: FeralinValue] = [
            "original_transaction_id": .string(String(snapshot.originalTransactionID)),
            "store": .string("app_store"),
            "product_kind": .string(snapshot.kind.rawValue),
        ]
        if let environment = snapshot.environment, !environment.isEmpty, environment.count <= 32 {
            properties["store_environment"] = .string(environment)
        }
        // JWS sınırı aşarsa makbuz gönderilmez; olay yine gider ama sunucu doğrulamaz (ESTIMATED kalır).
        var receipt: PurchaseReceipt?
        if let jws = snapshot.jws, !jws.isEmpty, jws.unicodeScalars.count <= RevenueEvent.maxReceiptToken {
            receipt = PurchaseReceipt(provider: .apple, token: jws)
        }
        return .track(RevenueInput(
            transactionID: String(snapshot.transactionID),
            amountMinor: amount,
            currency: currency,
            productID: snapshot.productID.isEmpty ? nil : snapshot.productID,
            quantity: max(1, snapshot.quantity),
            purchaseType: type,
            receipt: receipt,
            properties: properties
        ))
    }
}

// MARK: - Genel yüzey

extension FeralinClient {
    /// Satın alma ya da abonelik beyanı (`feralin_purchase`). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa
    /// REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez. Sözleşme dışı girdide, analitik izni
    /// yokken ve aynı işlem bu kurulumda zaten gönderilmişse `nil` döner; istemci kapalıysa `FeralinError.clientClosed`.
    @discardableResult
    public func trackRevenue(_ input: RevenueInput) throws -> TrackedEvent? {
        guard let properties = RevenueEvent.properties(input) else { return nil }
        let key = RevenueEvent.ledgerKey(transactionID: input.transactionID, purchaseType: input.purchaseType)
        if purchaseAlreadyTracked(key) { return nil }
        let event = try track(RevenueEvent.name, properties: properties)
        if event != nil { notePurchaseTracked(key) }
        return event
    }

    /// Ondalık tutarla gelir beyanı: `amount` para birimi cinsindendir (ör. StoreKit `Product.price`, 49.99) ve küçük birime
    /// sunucuyla aynı kuralla çevrilir. Para birimi StoreKit'te `product.priceFormatStyle.currencyCode`.
    @discardableResult
    public func trackRevenue(
        amount: Decimal,
        currency: String,
        productID: String? = nil,
        transactionID: String,
        quantity: Int = 1,
        purchaseType: PurchaseType = .purchase,
        receipt: PurchaseReceipt? = nil,
        properties: [String: FeralinValue]? = nil
    ) throws -> TrackedEvent? {
        guard let minor = MinorUnits.amountMinor(amount, currency: currency) else { return nil }
        return try trackRevenue(RevenueInput(
            transactionID: transactionID,
            amountMinor: minor,
            currency: currency,
            productID: productID,
            quantity: quantity,
            purchaseType: purchaseType,
            receipt: receipt,
            properties: properties
        ))
    }

    /// StoreKit işlem görüntüsünü işler (Apple köprüsü ve testler). Kapalı istemcide `FeralinError.clientClosed`.
    func recordStoreKitTransaction(_ snapshot: StoreKitTransactionSnapshot) throws -> StoreKitCaptureOutcome {
        switch StoreKitMapping.decide(snapshot) {
        case .skip(let outcome):
            return outcome
        case .track(let input):
            let key = RevenueEvent.ledgerKey(transactionID: input.transactionID, purchaseType: input.purchaseType)
            if purchaseAlreadyTracked(key) { return .duplicate }
            guard let event = try trackRevenue(input) else { return .notTracked }
            return .tracked(event)
        }
    }
}
