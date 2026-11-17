# frozen_string_literal: true

require "digest"

module Feralin
  # `fr_error` sözleşmesi (X4): hata sınıfı adı, temizlenmiş kısa mesaj, normalize edilmiş çerçevelerin özeti olan parmak izi ve en
  # üst çerçeve. Ham yığın izi (backtrace), dizin yolu ve kullanıcı verisi GİTMEZ. Sembolleştirme için uygulama çerçevelerinin konumu
  # ayrıca gider (`frames`: en çok 5; yalnız dosya taban adı, satır, işlev adı). Kurallar Android, Flutter ve Web SDK'larıyla aynıdır;
  # toplayıcı mesajı ayrıca temizler.
  module ErrorEvent
    NAME = "fr_error"
    ORIGIN_HANDLED = "handled"
    ORIGIN_MANUAL = "manual"
    ORIGIN_UNCAUGHT = "uncaught_exception"
    ORIGINS = [ORIGIN_HANDLED, ORIGIN_MANUAL, ORIGIN_UNCAUGHT].freeze
    MAX_MESSAGE = 200
    MAX_TYPE = 64
    MAX_FRAME = 160
    FINGERPRINT_FRAMES = 5
    MAX_LOCATIONS = 5
    MAX_FUNCTION = 60
    MAX_APP_VERSION = 32
    MAX_LINE = 10_000_000
    # Toplayıcının `frames[].file` kuralı: yalnız taban ad, dizin ve sorgu yok.
    LOCATION_FILE = /\A[A-Za-z0-9._~-]{1,128}\z/.freeze
    # Gem'ler, standart kütüphane ve yorumlayıcı içi çerçeveler uygulama çerçevesi sayılmaz.
    FRAMEWORK_PATH = %r{(\A<internal:)|(/gems/)|(/lib/ruby/)|(/rubygems/)}.freeze

    URL = %r{\b[a-z][a-z0-9+.\-]*://[^\s"'<>]+}i.freeze
    EMAIL = /[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/.freeze
    UUID = /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i.freeze
    TOKEN = %r{\b[A-Za-z0-9_\-+/=]{24,}\b}.freeze
    NUMBER = /\+?\d[\d\s\-().]{5,}\d/.freeze

    module_function

    # Mesajdan URL, e-posta, UUID, uzun belirteç ve uzun sayıları çıkarır; 200 karaktere kırpar. Sıra toplayıcıyla aynıdır.
    def scrub(message)
      text = message.to_s.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?")
      text = text.gsub(URL, "[url]").gsub(EMAIL, "[email]").gsub(UUID, "[id]")
      # Uzun belirteç: 24+ karakter ve en az bir rakam; rakamsız uzun sınıf adları bozulmaz.
      text = text.gsub(TOKEN) { |match| match.match?(/\d/) ? "[token]" : match }
      # Telefon, kart, kimlik numarası benzeri: ayraçlar dahil en az 7 rakam; kısa sürüm dizgeleri (1.4.2) bozulmaz.
      text = text.gsub(NUMBER) { |match| match.count("0-9") >= 7 ? "[num]" : match }
      text.strip.gsub(/\s+/, " ")[0, MAX_MESSAGE]
    end

    # Çerçeve: `işlev@dosya` (Web SDK biçimi); satır ve dizin yok, aynı hata kod kaydığında da aynı parmak izini üretir.
    def frame(location)
      "#{location.label}@#{File.basename(location.path.to_s)}"
    end

    def app_frame?(location)
      path = location.path.to_s
      !path.empty? && !FRAMEWORK_PATH.match?(path.tr("\\", "/"))
    end

    # Parmak izi: tür ve ilk beş çerçevenin SHA-256 özetinin ilk 16 baytı (32 onaltılık karakter).
    def fingerprint(type, frames, message)
      basis = frames.empty? ? message.gsub(/\d+/, "#") : frames.first(FINGERPRINT_FRAMES).join("|")
      Digest::SHA256.hexdigest("#{type}|#{basis}")[0, 32]
    end

    # Hata gövdesi; sözleşme alanlarının tamamı. app_version 1-32 karakterse eklenir.
    def properties(error, origin, fatal, app_version = nil)
      name = error.class.name.to_s.split("::").last.to_s[0, MAX_TYPE]
      name = "Error" if name.nil? || name.empty?
      message = scrub(error.message)
      all = error.backtrace_locations || []
      app = all.select { |location| app_frame?(location) }
      labels = (app.empty? ? all : app).map { |location| frame(location) }

      out = { "error_type" => name }
      out["message"] = message unless message.empty?
      out["fingerprint"] = fingerprint(name, labels, message)
      out["top_frame"] = labels.first[0, MAX_FRAME] unless labels.empty?
      out["frame_count"] = [labels.length, 1000].min
      out["app_version"] = app_version if app_version.is_a?(String) && !app_version.empty? && app_version.length <= MAX_APP_VERSION
      out["handled"] = [ORIGIN_HANDLED, ORIGIN_MANUAL].include?(origin)
      out["fatal"] = fatal ? true : false
      out["origin"] = origin
      positions = locations(app)
      out["frames"] = positions unless positions.empty?
      out
    end

    # Sembolleştirme konumları: uygulama çerçevelerinin ilk beşi; dosya taban adı, satır ve işlev adı. Satırı bilinmeyen ya da
    # toplayıcı kuralına sığmayan çerçeve listeye girmez.
    def locations(frames)
      out = []
      frames.each do |location|
        break if out.length >= MAX_LOCATIONS

        file = File.basename(location.path.to_s.tr("\\", "/"))
        line = location.lineno.to_i
        next if line < 1 || !LOCATION_FILE.match?(file)

        entry = { "file" => file, "line" => [line, MAX_LINE].min, "column" => 0 }
        function = location.base_label.to_s
        entry["function"] = function if !function.empty? && function.length <= MAX_FUNCTION
        out << entry
      end
      out
    end
  end

  # Hata fırtınası sınırı: pencere başına en çok max_events olay, aynı parmak izi için en çok max_per_fingerprint; örnekleme
  # sample_rate (0..1). Sayılar Android SDK'sıyla aynıdır (20 ve 3); sunucu süreci uzun yaşadığından süreç ömrü yerine 60 saniyelik
  # pencerede sayılır.
  class ErrorLimiter
    WINDOW = 60.0

    def initialize(max_events: 20, max_per_fingerprint: 3, sample_rate: 1.0)
      @max_events = max_events
      @max_per_fingerprint = max_per_fingerprint
      @sample_rate = sample_rate.to_f.clamp(0.0, 1.0)
      @lock = Mutex.new
      @window_start = nil
      @total = 0
      @per_fingerprint = Hash.new(0)
    end

    # now: saniye (Float); random: 0..1.
    def allow?(fingerprint, now, random)
      @lock.synchronize do
        if @window_start.nil? || now - @window_start >= WINDOW || now < @window_start
          @window_start = now
          @total = 0
          @per_fingerprint.clear
        end
        next false if @total >= @max_events
        next false if @sample_rate < 1.0 && random >= @sample_rate
        next false if @per_fingerprint[fingerprint] >= @max_per_fingerprint

        @per_fingerprint[fingerprint] += 1
        @total += 1
        true
      end
    end
  end
end
