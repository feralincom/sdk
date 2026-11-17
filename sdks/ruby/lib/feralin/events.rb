# frozen_string_literal: true

require_relative "errors"

module Feralin
  # İzin anlık görüntüsü. analytics doğru değilse hiçbir olay üretilmez. Yalnız gerçek `true` izin sayılır;
  # "false" gibi doğru sayılan bir değer yanlışlıkla izin vermesin. Tüm alanlar açıkça gönderilir.
  class Consent
    attr_reader :analytics, :advertising, :personalization, :session_replay

    def initialize(analytics: false, advertising: false, personalization: false, session_replay: false)
      @analytics = analytics == true
      @advertising = advertising == true
      @personalization = personalization == true
      @session_replay = session_replay == true
      freeze
    end

    def to_h
      {
        "analytics" => analytics,
        "advertising" => advertising,
        "personalization" => personalization,
        "session_replay" => session_replay
      }
    end

    def ==(other)
      other.is_a?(Consent) && to_h == other.to_h
    end
  end

  class Screen
    attr_reader :width, :height

    def initialize(width:, height:)
      @width = width
      @height = height
      freeze
    end
  end

  class AppInfo
    attr_reader :version, :build

    def initialize(version: nil, build: nil)
      @version = version
      @build = build
      freeze
    end
  end

  # Şemadaki context nesnesi; yalnız dolu alanlar gönderilir.
  class Context
    TEXT_FIELDS = %i[page_url page_title referrer locale timezone].freeze

    attr_reader(*TEXT_FIELDS, :screen, :app)

    def initialize(page_url: nil, page_title: nil, referrer: nil, locale: nil, timezone: nil, screen: nil, app: nil)
      @page_url = page_url
      @page_title = page_title
      @referrer = referrer
      @locale = locale
      @timezone = timezone
      @screen = screen
      @app = app
      freeze
    end

    def to_h
      out = {}
      TEXT_FIELDS.each do |field|
        value = public_send(field).to_s
        out[field.to_s] = value unless value.empty?
      end
      out["screen"] = { "width" => screen.width, "height" => screen.height } if screen
      if app
        info = {}
        info["version"] = app.version.to_s unless app.version.to_s.empty?
        info["build"] = app.build.to_s unless app.build.to_s.empty?
        out["app"] = info unless info.empty?
      end
      out
    end
  end

  # Bir flush çağrısının toplu sonucu.
  class FlushResult
    attr_reader :sent, :accepted, :rejected, :batch_id, :status, :retained, :error

    def initialize(sent: 0, accepted: 0, rejected: 0, batch_id: nil, status: 0, retained: 0, error: nil)
      @sent = sent
      @accepted = accepted
      @rejected = rejected
      @batch_id = batch_id
      @status = status
      @retained = retained
      @error = error
      freeze
    end

    def ok?
      error.nil?
    end
  end

  # UTP v1 istemci tarafı doğrulama (packages/schemas/utp/v1/event.schema.json ile birebir).
  # tenant_id, project_id ve verified alanları istemciden asla gönderilmez.
  module Events
    MAX_EVENT_NAME_LENGTH = 100
    MAX_PROPERTIES = 100
    MAX_IDENTIFIER_LENGTH = 128
    MAX_VALUE_DEPTH = 32
    ATTRIBUTION_CLICK_PROPERTY = "fr_click"

    # Ruby'de ^ ve $ satır çapasıdır; çok satırlı değer geçmesin diye \A ve \z kullanılır.
    EVENT_NAME_FORMAT = /\A[a-z][a-z0-9_]*\z/.freeze
    PROPERTY_KEY_FORMAT = /\A[a-zA-Z][a-zA-Z0-9_]{0,63}\z/.freeze

    FNV_OFFSET = 0xCBF29CE484222325
    FNV_PRIME = 0x100000001B3
    FNV_MASK = 0xFFFFFFFFFFFFFFFF

    module_function

    # Web, Node, .NET, Android, Flutter ve Python SDK'larıyla aynı anahtar: sıralı tüm event_id'lerin FNV-1a 64 özeti ve sayı.
    def idempotency_key_for(event_ids)
      ordered = event_ids.sort
      value = FNV_OFFSET
      ordered.join(",").each_byte do |byte|
        value = ((value ^ byte) * FNV_PRIME) & FNV_MASK
      end
      format("%016x-%d", value, ordered.length)
    end

    def validate_event_name(name)
      text = name.is_a?(Symbol) ? name.to_s : name
      unless text.is_a?(String) && !text.empty? && text.length <= MAX_EVENT_NAME_LENGTH && EVENT_NAME_FORMAT.match?(text)
        raise InvalidEventError, "event_name snake_case olmalı (^[a-z][a-z0-9_]*$, en fazla 100 karakter)"
      end

      text
    end

    # Hash'i tel biçimine çevirir: anahtarlar metin olur, değerler derinlemesine denetlenir. Boşsa nil döner.
    def validate_properties(properties)
      return nil if properties.nil?
      raise InvalidEventError, "properties bir Hash olmalı" unless properties.is_a?(Hash)

      if properties.length > MAX_PROPERTIES
        raise InvalidEventError, "properties en fazla 100 anahtar içerebilir (#{properties.length} verildi)"
      end

      out = {}
      properties.each do |key, value|
        text = key.is_a?(Symbol) ? key.to_s : key
        unless text.is_a?(String) && PROPERTY_KEY_FORMAT.match?(text)
          raise InvalidEventError, "properties anahtarı ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ desenine uymalı"
        end

        out[text] = normalize_value(value, 1)
      end
      out.empty? ? nil : out
    end

    def validate_identifier(value, field_name)
      return nil if value.nil? || value == ""
      unless value.is_a?(String) && value.length <= MAX_IDENTIFIER_LENGTH
        raise InvalidEventError, "#{field_name} en fazla 128 karakterlik metin olmalı"
      end

      value
    end

    # UTC RFC3339, milisaniye hassasiyeti (ör. 2026-11-03T10:00:00.123Z).
    def format_time(moment)
      # Metin kabul edilmez: ActiveSupport String#to_time ekler ve yerel saati tahmin ederdi.
      time = moment.is_a?(String) || !moment.respond_to?(:to_time) ? moment : moment.to_time
      raise InvalidEventError, "occurred_at bir Time olmalı" unless time.is_a?(Time)

      time.getutc.strftime("%Y-%m-%dT%H:%M:%S.%LZ")
    end

    # JSON.generate bilinmeyen nesneyi to_s ile metne çevirir (#<Object:0x...>); veri sessizce bozulmasın diye
    # yalnız JSON karşılığı olan türler kabul edilir. Derinlik sınırı döngüsel yapıyı da yakalar.
    def normalize_value(value, depth)
      raise InvalidEventError, "properties değeri en fazla #{MAX_VALUE_DEPTH} düzey iç içe olabilir" if depth > MAX_VALUE_DEPTH

      case value
      when nil, true, false, Integer then value
      when Float
        raise InvalidEventError, "properties değeri sonlu sayı olmalı" unless value.finite?

        value
      when String then normalize_string(value)
      when Symbol then value.to_s
      when Array then value.map { |item| normalize_value(item, depth + 1) }
      when Hash then normalize_hash(value, depth)
      else
        raise InvalidEventError, "properties değeri JSON'a dönüştürülemez: #{value.class}"
      end
    end
    private_class_method :normalize_value

    def normalize_hash(value, depth)
      value.each_with_object({}) do |(key, item), out|
        unless key.is_a?(String) || key.is_a?(Symbol)
          raise InvalidEventError, "properties içindeki anahtar metin olmalı: #{key.class}"
        end

        out[normalize_string(key.to_s)] = normalize_value(item, depth + 1)
      end
    end
    private_class_method :normalize_hash

    def normalize_string(value)
      text = value.encoding == Encoding::UTF_8 ? value : value.encode(Encoding::UTF_8)
      raise InvalidEventError, "properties metni geçerli UTF-8 olmalı" unless text.valid_encoding?

      text
    rescue EncodingError
      raise InvalidEventError, "properties metni geçerli UTF-8 olmalı"
    end
    private_class_method :normalize_string
  end
end
