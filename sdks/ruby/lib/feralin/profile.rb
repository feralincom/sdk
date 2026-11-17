# frozen_string_literal: true

module Feralin
  # UTP §8.2 kimlik yöntemleri: `group` → `fr_group`, `set_user_properties` → `fr_user_properties`. Kurallar bütün SDK'larda
  # (sdks/node/src/profile.ts) ve toplayıcıda (services/collect/internal/httpapi/profile_filter.go) birebir aynıdır; toplayıcı
  # ayrıca projenin izin listesini uygular (liste boşsa hiçbir kullanıcı özelliği saklanmaz).
  module Profile
    GROUP_EVENT_NAME = "fr_group"
    USER_PROPERTIES_EVENT_NAME = "fr_user_properties"
    MAX_PROPERTIES = 50
    MAX_VALUE_LENGTH = 256
    MAX_GROUP_ID_LENGTH = 128

    KEY_FORMAT = /\A[a-zA-Z][a-zA-Z0-9_]{0,63}\z/.freeze
    EMAIL_FORMAT = /[^\s@]+@[^\s@]+\.[^\s@]+/.freeze
    CONTROL_FORMAT = /\p{Cc}/.freeze
    # İstemci doğrulama beyan edemez: sunucu alanları düşer.
    RESERVED_KEYS = %w[verified verification verification_source receipt_provider receipt_digest receipt].freeze
    # Kişisel veri anahtar kuralı (toplayıcıdaki piiTokens, piiFragments, piiExact ile aynı listeler).
    PII_TOKENS = %w[
      email mail phone tel telephone mobile msisdn gsm ip ipv4 ipv6 ssn tckn passport password iban
      address adres eposta telefon soyad surname firstname lastname fullname birthdate birthday dob
    ].freeze
    PII_FRAGMENTS = %w[email phonenumber ipaddress firstname lastname fullname surname soyad eposta telefon password birthdate].freeze
    PII_EXACT = %w[name username displayname isim ad].freeze

    module_function

    # Anahtarı sözcüklere böler: küçük harf ya da rakamdan sonra gelen büyük harf yeni sözcük başlatır; alt çizgi ayırıcıdır.
    def key_tokens(key)
      key.gsub(/(?<=[\p{Ll}\p{Nd}])(?=\p{Lu})/, "_").downcase.split("_").reject(&:empty?)
    end

    # Anahtar kişisel veriye (e-posta, telefon, IP, ad soyad, adres, kimlik numarası, parola, doğum tarihi) benziyor mu.
    def pii_like_key?(key)
      tokens = key_tokens(key)
      return true if tokens.any? { |token| PII_TOKENS.include?(token) }

      joined = tokens.join
      PII_EXACT.include?(joined) || PII_FRAGMENTS.any? { |fragment| joined.include?(fragment) }
    end

    def valid_value?(value)
      case value
      when true, false, Integer then true
      when Float then value.finite?
      when String
        value.valid_encoding? && value.length <= MAX_VALUE_LENGTH && !EMAIL_FORMAT.match?(value) && !CONTROL_FORMAT.match?(value)
      else false
      end
    end

    # Özellikleri kimlik sözleşmesine indirger; geçersiz anahtar ve değer düşer, 50 özellikten sonrası alınmaz.
    def sanitize(properties)
      out = {}
      return out unless properties.is_a?(Hash)

      properties.each do |key, value|
        break if out.length >= MAX_PROPERTIES

        name = key.is_a?(Symbol) ? key.to_s : key
        next unless name.is_a?(String) && KEY_FORMAT.match?(name)
        next if RESERVED_KEYS.include?(name) || pii_like_key?(name)
        next unless valid_value?(value)

        out[name] = value
      end
      out
    end

    # Grup kimliği: 1-128 karakter, yalnız boşluk değil, `@` ve kontrol karakteri yok (kişisel veri taşımamalı).
    def valid_group_id?(group_id)
      group_id.is_a?(String) && group_id.valid_encoding? && !group_id.strip.empty? &&
        group_id.length <= MAX_GROUP_ID_LENGTH && !group_id.include?("@") && !CONTROL_FORMAT.match?(group_id)
    end
  end
end
