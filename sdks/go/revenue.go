package feralin

import (
	"context"
	"errors"
	"regexp"
	"time"
)

// RevenueEventName trackRevenue sözleşmesinin tek olay adıdır (F5-E04-T01); defter yalnız bu olaydan beslenir.
const RevenueEventName = "feralin_purchase"

// MaxAmountMinor küçük birimde tutarın üst sınırıdır (JS güvenli tam sayı); sunucu bigint taşır.
const MaxAmountMinor int64 = 1<<53 - 1

// ErrInvalidRevenue gelir girdisi sözleşmeye uymuyor: işlem kimliği 1..128, tutar 0..2^53-1 tam sayı (küçük birim), para birimi
// ISO 4217 üç büyük harf, adet 0..100000, makbuz sağlayıcısı apple|google|stripe ve dolu belirteç.
var ErrInvalidRevenue = errors.New("feralin: gelir girdisi geçersiz (transaction_id, amount_minor küçük birimde tam sayı, currency ISO 4217)")

var currencyRe = regexp.MustCompile(`^[A-Z]{3}$`)

// Satın alma türleri.
const (
	PurchaseTypePurchase           = "purchase"
	PurchaseTypeSubscriptionStart  = "subscription_start"
	PurchaseTypeSubscriptionRenew  = "subscription_renew"
	PurchaseTypeSubscriptionCancel = "subscription_cancel"
)

// Receipt isteğe bağlı ham makbuzdur; toplayıcı yalnız sağlayıcı adını ve belirtecin SHA-256 özetini saklar.
type Receipt struct {
	// Provider apple, google ya da stripe.
	Provider string
	// Token sağlayıcının verdiği makbuz ya da satın alma belirteci (en çok 8192 karakter).
	Token string
}

// Revenue TrackRevenue girdisidir. İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa REAL_VERIFIED sayar,
// aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez.
type Revenue struct {
	// TransactionID mağaza, ödeme sağlayıcısı ya da kendi sipariş kimliğiniz; sunucu aynı işlemi ikinci kez saymaz.
	TransactionID string
	// AmountMinor küçük birimde satır toplamı: 49,99 TL için 4999. Ondalık yoktur; Quantity ile çarpılmaz. Abonelik iptalinde 0.
	AmountMinor int64
	// Currency ISO 4217, üç büyük harf.
	Currency string
	// ProductID isteğe bağlı ürün kimliği (en çok 128 karakter).
	ProductID string
	// Quantity adet (bilgi amaçlı); Go'da sıfır değer "verilmedi" demektir ve 1 yazılır, 0 adet gönderilemez. Üst sınır 100000.
	Quantity int
	// PurchaseType boşsa "purchase".
	PurchaseType string
	// Receipt isteğe bağlı ham makbuz.
	Receipt *Receipt
	// Properties ek özellikler; verified ve türevleri düşürülür.
	Properties map[string]any
	// Kimlikler ve bağlam Event ile aynıdır.
	UserID      string
	AnonymousID string
	SessionID   string
	OccurredAt  time.Time
	Context     *Context
}

// revenueReservedKeys istemcinin beyan edemeyeceği alanlardır; çağıranın özelliklerinden düşürülür, sunucu da düşürür.
var revenueReservedKeys = []string{"verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt"}

// RevenueProperties gelir girdisini sözleşme özelliklerine çevirir; geçersiz girdide ErrInvalidRevenue döner.
func RevenueProperties(r Revenue) (map[string]any, error) {
	if r.TransactionID == "" || len(r.TransactionID) > 128 {
		return nil, ErrInvalidRevenue
	}
	if r.AmountMinor < 0 || r.AmountMinor > MaxAmountMinor {
		return nil, ErrInvalidRevenue
	}
	if !currencyRe.MatchString(r.Currency) {
		return nil, ErrInvalidRevenue
	}
	if len(r.ProductID) > 128 {
		return nil, ErrInvalidRevenue
	}
	quantity := r.Quantity
	if quantity == 0 {
		quantity = 1
	}
	if quantity < 0 || quantity > 100000 {
		return nil, ErrInvalidRevenue
	}
	purchaseType := r.PurchaseType
	if purchaseType == "" {
		purchaseType = PurchaseTypePurchase
	}
	switch purchaseType {
	case PurchaseTypePurchase, PurchaseTypeSubscriptionStart, PurchaseTypeSubscriptionRenew, PurchaseTypeSubscriptionCancel:
	default:
		return nil, ErrInvalidRevenue
	}
	// Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
	if purchaseType == PurchaseTypeSubscriptionCancel && r.AmountMinor != 0 {
		return nil, ErrInvalidRevenue
	}
	if r.Receipt != nil {
		switch r.Receipt.Provider {
		case "apple", "google", "stripe":
		default:
			return nil, ErrInvalidRevenue
		}
		if r.Receipt.Token == "" || len(r.Receipt.Token) > 8192 {
			return nil, ErrInvalidRevenue
		}
	}
	props := make(map[string]any, len(r.Properties)+8)
	for k, v := range r.Properties {
		props[k] = v
	}
	for _, key := range revenueReservedKeys {
		delete(props, key)
	}
	props["transaction_id"] = r.TransactionID
	props["amount_minor"] = r.AmountMinor
	props["currency"] = r.Currency
	props["quantity"] = quantity
	props["purchase_type"] = purchaseType
	if r.ProductID != "" {
		props["product_id"] = r.ProductID
	}
	if r.Receipt != nil {
		props["receipt"] = map[string]any{"provider": r.Receipt.Provider, "token": r.Receipt.Token}
	}
	return props, nil
}

// TrackRevenue satın alma ya da abonelik beyanını `feralin_purchase` olayı olarak kuyruğa ekler. Track ile aynı izin ve kuyruk
// kurallarına tabidir; sözleşme dışı girdide (nil, ErrInvalidRevenue) döner.
func (c *Client) TrackRevenue(ctx context.Context, r Revenue) (*UtpEvent, error) {
	props, err := RevenueProperties(r)
	if err != nil {
		return nil, err
	}
	return c.Track(ctx, Event{
		Name:        RevenueEventName,
		Properties:  props,
		UserID:      r.UserID,
		AnonymousID: r.AnonymousID,
		SessionID:   r.SessionID,
		OccurredAt:  r.OccurredAt,
		Context:     r.Context,
	})
}
