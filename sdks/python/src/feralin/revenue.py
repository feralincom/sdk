"""`track_revenue` sözleşmesi (F5-E04-T01): olay adı `feralin_purchase`; tutar küçük birimde tam sayı (kuruş, cent), para birimi
ISO 4217. İstemci beyanıdır: `verified` hiçbir zaman gönderilmez, doğrulama sunucu tarafı makbuz doğrulayıcısınındır."""

from __future__ import annotations

import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

from .errors import InvalidEventError

REVENUE_EVENT_NAME = "feralin_purchase"
PURCHASE_TYPES = ("purchase", "subscription_start", "subscription_renew", "subscription_cancel")
RECEIPT_PROVIDERS = ("apple", "google", "stripe")
MAX_AMOUNT_MINOR = 2**53 - 1
MAX_QUANTITY = 100_000

# İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
_RESERVED_KEYS = ("verified", "verification", "verification_source", "receipt_provider", "receipt_digest", "receipt")
_CURRENCY_RE = re.compile(r"^[A-Z]{3}$")


@dataclass(frozen=True, slots=True)
class Receipt:
    """İsteğe bağlı ham makbuz; toplayıcı yalnız sağlayıcı adını ve belirtecin SHA-256 özetini saklar."""

    provider: str
    token: str


def revenue_properties(
    transaction_id: str,
    amount_minor: int,
    currency: str,
    *,
    product_id: str | None = None,
    quantity: int = 1,
    purchase_type: str = "purchase",
    receipt: Receipt | None = None,
    properties: Mapping[str, Any] | None = None,
) -> dict[str, Any]:
    """Gelir olayının özelliklerini kurar; sözleşme dışı girdide InvalidEventError fırlatır. Kurallar bütün SDK'larda aynıdır.
    amount_minor satır toplamıdır (quantity ile çarpılmaz); abonelik iptalinde 0."""
    if not isinstance(transaction_id, str) or not 1 <= len(transaction_id) <= 128:
        raise InvalidEventError("transaction_id 1..128 karakterlik metin olmalı")
    # bool int alt türüdür; True/False tutar sayılmaz.
    if isinstance(amount_minor, bool) or not isinstance(amount_minor, int) or not 0 <= amount_minor <= MAX_AMOUNT_MINOR:
        raise InvalidEventError("amount_minor küçük birimde (kuruş, cent) 0..2^53-1 tam sayı olmalı; ondalık kabul edilmez")
    if not isinstance(currency, str) or not _CURRENCY_RE.match(currency):
        raise InvalidEventError("currency ISO 4217 üç büyük harf olmalı")
    if product_id is not None and (not isinstance(product_id, str) or not 1 <= len(product_id) <= 128):
        raise InvalidEventError("product_id 1..128 karakterlik metin olmalı")
    if isinstance(quantity, bool) or not isinstance(quantity, int) or not 0 <= quantity <= MAX_QUANTITY:
        raise InvalidEventError("quantity 0..100000 tam sayı olmalı")
    if purchase_type not in PURCHASE_TYPES:
        raise InvalidEventError("purchase_type %s değerlerinden biri olmalı" % "|".join(PURCHASE_TYPES))
    # Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
    if purchase_type == "subscription_cancel" and amount_minor != 0:
        raise InvalidEventError("subscription_cancel için amount_minor 0 olmalı")
    if receipt is not None:
        if not isinstance(receipt, Receipt) or receipt.provider not in RECEIPT_PROVIDERS:
            raise InvalidEventError("receipt.provider apple|google|stripe olmalı")
        if not isinstance(receipt.token, str) or not 1 <= len(receipt.token) <= 8192:
            raise InvalidEventError("receipt.token 1..8192 karakterlik metin olmalı")
    props: dict[str, Any] = dict(properties) if properties else {}
    for key in _RESERVED_KEYS:
        props.pop(key, None)
    props["transaction_id"] = transaction_id
    props["amount_minor"] = amount_minor
    props["currency"] = currency
    props["quantity"] = quantity
    props["purchase_type"] = purchase_type
    if product_id is not None:
        props["product_id"] = product_id
    if receipt is not None:
        props["receipt"] = {"provider": receipt.provider, "token": receipt.token}
    return props
