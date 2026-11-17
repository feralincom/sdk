# frozen_string_literal: true

require_relative "errors"

module Feralin
  # `track_revenue` sözleşmesi (F5-E04-T01): olay adı `feralin_purchase`; tutar küçük birimde tam sayı (kuruş, cent), para birimi
  # ISO 4217. İstemci beyanıdır: `verified` hiçbir zaman gönderilmez, doğrulama sunucu tarafı makbuz doğrulayıcısınındır. Kurallar
  # Web, Node, Python, Go ve .NET SDK'larıyla birebir aynıdır.
  module Revenue
    EVENT_NAME = "feralin_purchase"
    PURCHASE_TYPES = %w[purchase subscription_start subscription_renew subscription_cancel].freeze
    RECEIPT_PROVIDERS = %w[apple google stripe].freeze
    MAX_AMOUNT_MINOR = (2**53) - 1
    MAX_QUANTITY = 100_000

    # İstemci doğrulama beyan edemez: bu anahtarlar çağıranın özelliklerinden düşürülür, sunucu da düşürür.
    RESERVED_KEYS = %w[verified verification verification_source receipt_provider receipt_digest receipt].freeze
    CURRENCY_FORMAT = /\A[A-Z]{3}\z/.freeze

    module_function

    # Gelir olayının özelliklerini kurar; sözleşme dışı girdide InvalidEventError fırlatır. amount_minor satır toplamıdır
    # (quantity ile çarpılmaz); abonelik iptalinde 0. receipt: { provider: "apple"|"google"|"stripe", token: "..." }.
    def properties(transaction_id:, amount_minor:, currency:, product_id: nil, quantity: 1, purchase_type: "purchase",
                   receipt: nil, properties: nil)
      unless transaction_id.is_a?(String) && transaction_id.length.between?(1, 128)
        raise InvalidEventError, "transaction_id 1..128 karakterlik metin olmalı"
      end
      # Integer dışı (Float, BigDecimal, metin) kabul edilmez; kayan nokta yuvarlaması defteri bozardı.
      unless amount_minor.is_a?(Integer) && amount_minor.between?(0, MAX_AMOUNT_MINOR)
        raise InvalidEventError, "amount_minor küçük birimde (kuruş, cent) 0..2^53-1 tam sayı olmalı; ondalık kabul edilmez"
      end
      raise InvalidEventError, "currency ISO 4217 üç büyük harf olmalı" unless currency.is_a?(String) && CURRENCY_FORMAT.match?(currency)
      if !product_id.nil? && !(product_id.is_a?(String) && product_id.length.between?(1, 128))
        raise InvalidEventError, "product_id 1..128 karakterlik metin olmalı"
      end
      unless quantity.is_a?(Integer) && quantity.between?(0, MAX_QUANTITY)
        raise InvalidEventError, "quantity 0..100000 tam sayı olmalı"
      end

      type = purchase_type.is_a?(Symbol) ? purchase_type.to_s : purchase_type
      raise InvalidEventError, "purchase_type #{PURCHASE_TYPES.join('|')} değerlerinden biri olmalı" unless PURCHASE_TYPES.include?(type)
      # Abonelik iptali para taşımaz; defter tutarlı iptali reddeder.
      if type == "subscription_cancel" && amount_minor != 0
        raise InvalidEventError, "subscription_cancel için amount_minor 0 olmalı"
      end

      receipt_value = normalize_receipt(receipt)
      raise InvalidEventError, "properties bir Hash olmalı" unless properties.nil? || properties.is_a?(Hash)

      # Sözleşme alanları önce yazılır: 100 özellik sınırını aşan girdi çağıranın ek alanlarıdır.
      props = {
        "transaction_id" => transaction_id,
        "amount_minor" => amount_minor,
        "currency" => currency,
        "quantity" => quantity,
        "purchase_type" => type
      }
      props["product_id"] = product_id unless product_id.nil?
      props["receipt"] = receipt_value if receipt_value
      (properties || {}).each do |key, value|
        name = key.is_a?(Symbol) ? key.to_s : key
        props[name] = value unless RESERVED_KEYS.include?(name) || props.key?(name)
      end
      props
    end

    def normalize_receipt(receipt)
      return nil if receipt.nil?
      raise InvalidEventError, "receipt bir Hash olmalı" unless receipt.is_a?(Hash)

      provider = receipt[:provider] || receipt["provider"]
      provider = provider.to_s if provider.is_a?(Symbol)
      token = receipt[:token] || receipt["token"]
      raise InvalidEventError, "receipt.provider apple|google|stripe olmalı" unless RECEIPT_PROVIDERS.include?(provider)
      raise InvalidEventError, "receipt.token 1..8192 karakterlik metin olmalı" unless token.is_a?(String) && token.length.between?(1, 8192)

      { "provider" => provider, "token" => token }
    end
  end
end
