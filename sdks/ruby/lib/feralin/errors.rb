# frozen_string_literal: true

module Feralin
  # Tüm SDK hatalarının tabanı. Teslim hataları FlushResult#error içinde döner; flush fırlatmaz.
  class Error < StandardError; end

  # Geçersiz proje anahtarı, collect_url veya seçenek.
  class ConfigurationError < Error; end

  # event_name, properties veya kimlik alanı UTP v1 kurallarına uymuyor.
  class InvalidEventError < Error; end

  # close sonrası track veya flush çağrıldı.
  class ClientClosedError < Error; end

  # Toplayıcıya gönderim hatası; status 0 ise ağ hatasıdır.
  class DeliveryError < Error
    attr_reader :status, :detail

    def initialize(message = nil, status: 0, detail: "")
      super(message)
      @status = status
      @detail = detail
    end
  end

  # 4xx (429 hariç): batch kalıcı olarak reddedildi, olaylar kuyruktan atıldı.
  class RejectedError < DeliveryError; end

  # 5xx, 429 veya ağ hatası: olaylar kuyrukta tutuldu, aynı Idempotency-Key ile yeniden denenecek.
  class TemporaryError < DeliveryError; end
end
