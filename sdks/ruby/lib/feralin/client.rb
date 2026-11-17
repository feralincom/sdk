# frozen_string_literal: true

require "json"
require "uri"
require_relative "errors"
require_relative "error_event"
require_relative "events"
require_relative "profile"
require_relative "revenue"
require_relative "transport"
require_relative "ulid"
require_relative "version"

module Feralin
  # Feralin UTP v1 sunucu istemcisi. POST /v1/batch ile olay gönderir, iş parçacığı güvenlidir.
  #
  # İlkeler (Web SDK ile tutarlı):
  # - consent.analytics doğru değilse olay üretilmez; track sessizce nil döner.
  # - En az bir kez teslim: 202 onay; 4xx (429 hariç) olaylar atılır; 5xx, 429 ve ağ hatasında kuyrukta tutulur ve üstel
  #   geri çekilmeyle (1 sn - 30 sn, yarım jitter) yeniden denenir. Aynı batch aynı Idempotency-Key ile gider.
  # - Yalnız proje public anahtarı (pk_) kabul edilir; gizli anahtar (sk_) reddedilir. tenant_id ve verified
  #   asla gönderilmez; bunları sunucu çözer.
  # - Kuyruk süreç başınadır. Puma veya Unicorn çatallanınca yavru kendi boş kuyruğu ve göndericisiyle devam eder;
  #   üst süreçteki olaylar yavrudan bir daha gönderilmez.
  class Client
    SDK_NAME = "feralin-ruby"
    SDK_VERSION = VERSION
    PLATFORM = "ruby"
    SCHEMA_VERSION = 1

    MAX_BATCH_SIZE = 500
    DEFAULT_BATCH_SIZE = 100
    DEFAULT_QUEUE_LIMIT = 1000
    DEFAULT_FLUSH_INTERVAL = 2.0
    DEFAULT_TIMEOUT = 10.0
    CLOSE_TIMEOUT = 5.0

    MIN_BACKOFF = 1.0
    MAX_BACKOFF = 30.0

    # Varsayılan günlük: uyarılar standart hataya gider. logger gem'i yeni Ruby'lerde varsayılan olmaktan çıktığından
    # çalışma zamanı bağımlılığı doğmasın diye kullanılmaz; Logger arayüzlü her nesne verilebilir.
    class StderrLogger
      def debug(_message = nil); end

      def warn(message = nil)
        $stderr.puts(message)
      end
    end

    # Bloklu kullanım: blok bitince kalan olaylar gönderilir ve istemci kapatılır.
    def self.open(*args, **options)
      client = new(*args, **options)
      return client unless block_given?

      begin
        yield client
      ensure
        client.close
      end
    end

    def initialize(project_key, collect_url, consent: nil, flush_interval: DEFAULT_FLUSH_INTERVAL,
                   batch_size: DEFAULT_BATCH_SIZE, queue_limit: DEFAULT_QUEUE_LIMIT, timeout: DEFAULT_TIMEOUT,
                   transport: nil, now: nil, logger: nil, app_version: nil, error_sample_rate: 1.0)
      key = project_key.to_s.strip
      if key.start_with?("sk_")
        raise ConfigurationError, "gizli anahtar (sk_) SDK'da kullanılamaz; proje public anahtarını (pk_) verin"
      end
      raise ConfigurationError, "proje anahtarı pk_ ile başlamalı" if !key.start_with?("pk_") || key.length < 8
      raise ConfigurationError, "consent bir Feralin::Consent örneği olmalı" unless consent.nil? || consent.is_a?(Consent)
      raise ConfigurationError, "transport call metodu sunmalı" unless transport.nil? || transport.respond_to?(:call)

      @project_key = key
      @endpoint = "#{parse_collect_url(collect_url)}/v1/batch"
      @consent = consent || Consent.new
      @flush_interval = number_option("flush_interval", flush_interval)
      @batch_size = number_option("batch_size", batch_size).to_i.clamp(1, MAX_BATCH_SIZE)
      @queue_limit = [number_option("queue_limit", queue_limit).to_i, 1].max
      @timeout = number_option("timeout", timeout)
      raise ConfigurationError, "timeout pozitif olmalı" unless @timeout.positive?

      @transport = transport || Transport.method(:net_http)
      @now = now || -> { Time.now }
      @logger = logger || StderrLogger.new
      # fr_error olayına yazılır (en çok 32 karakter); hata olayları pencere başına sınırlanır ve örneklenir.
      @app_version = app_version.is_a?(String) ? app_version : nil
      @error_limiter = ErrorLimiter.new(sample_rate: number_option("error_sample_rate", error_sample_rate))

      @lock = Mutex.new # kuyruk, izin, kimlik, geri çekilme
      @opted_out = false
      @user_id = nil
      @closed = false
      @dropped = 0
      prepare_process_state
      start_thread
    end

    # İzin durumunu günceller. analytics doğru değilse bekleyen olaylar atılır, yeni olay üretilmez ve olay başına
    # verilen izin de geçersiz sayılır (açık geri çekme).
    def set_consent(consent)
      raise InvalidEventError, "consent bir Feralin::Consent örneği olmalı" unless consent.is_a?(Consent)

      ensure_current_process
      @lock.synchronize do
        @consent = consent
        @opted_out = !consent.analytics
        if @opted_out
          @queue.clear
          @pinned = nil
        end
      end
      nil
    end

    # Sonraki olaylar için varsayılan user_id (olay başına user_id önceliklidir). nil varsayılanı kaldırır.
    # İstemci süreçte paylaşılır; çok kullanıcılı sunucuda istek başına Feralin::Rack::Tracker#identify kullanın.
    def identify(user_id)
      value = Events.validate_identifier(user_id, "user_id")
      @lock.synchronize { @user_id = value }
      nil
    end

    # Satın alma ya da abonelik beyanı (`feralin_purchase`). İstemci beyanıdır: sunucu satırı yalnız makbuz doğrulayıcısı onaylarsa
    # REAL_VERIFIED sayar, aksi hâlde ESTIMATED kalır; `verified` alanı hiçbir zaman gönderilmez. amount_minor küçük birimde satır
    # toplamıdır (49,99 TL için 4999). Sözleşme dışı girdide InvalidEventError fırlatır; izin yoksa nil döner.
    # Diğer anahtar sözcükler track ile aynıdır (user_id, anonymous_id, session_id, occurred_at, context, consent).
    def track_revenue(transaction_id, amount_minor, currency, product_id: nil, quantity: 1, purchase_type: "purchase",
                      receipt: nil, properties: nil, **options)
      props = Revenue.properties(transaction_id: transaction_id, amount_minor: amount_minor, currency: currency,
                                 product_id: product_id, quantity: quantity, purchase_type: purchase_type,
                                 receipt: receipt, properties: properties)
      track(Revenue::EVENT_NAME, props, **options)
    end

    # Kullanıcıyı bir gruba (hesap, ekip, kuruluş) bağlar: `fr_group` olayı, `group_id` ve temizlenmiş özellikler. Grup kimliği
    # 1-128 karakter olmalı, `@` ve kontrol karakteri içermemelidir; uymazsa olay üretilmez ve nil döner. Toplayıcı yalnız projenin
    # izin listesindeki özellikleri saklar.
    def group(group_id, traits = nil, **options)
      unless Profile.valid_group_id?(group_id)
        @logger.warn("feralin: fr_group: geçersiz group_id, olay üretilmedi")
        return nil
      end

      props = Profile.sanitize(traits)
      props["group_id"] = group_id
      track(Profile::GROUP_EVENT_NAME, props, **options)
    end

    # Kullanıcı özelliklerini bildirir: `fr_user_properties` olayı. Değer metin (≤256 karakter, e-posta biçiminde değil), sonlu
    # sayı ya da mantıksal olmalı; kişisel veriye benzeyen anahtar ve doğrulama alanı düşer. Geçerli özellik yoksa nil döner.
    def set_user_properties(properties, **options)
      props = Profile.sanitize(properties)
      if props.empty?
        @logger.warn("feralin: fr_user_properties: geçerli özellik yok, olay üretilmedi")
        return nil
      end

      track(Profile::USER_PROPERTIES_EVENT_NAME, props, **options)
    end

    # Yakalanan bir hatayı `fr_error` olarak bildirir. Ham yığın izi gitmez: hata sınıfı adı, temizlenmiş mesaj, çerçeve özeti olan
    # parmak izi ve sembolleştirme için en çok 5 uygulama çerçevesinin konumu (dosya taban adı, satır, işlev) gider. 60 saniyede en
    # çok 20 olay, aynı parmak izi için en çok 3 olay. origin: handled (varsayılan), manual ya da uncaught_exception; fatal
    # varsayılan olarak yalnız uncaught_exception için doğrudur. Hiçbir durumda fırlatmaz; olay üretilmezse nil döner.
    def capture_error(error, origin: ErrorEvent::ORIGIN_HANDLED, fatal: nil, app_version: nil, **options)
      return nil unless error.is_a?(Exception)

      origin = origin.to_s if origin.is_a?(Symbol)
      unless ErrorEvent::ORIGINS.include?(origin)
        @logger.warn("feralin: fr_error: geçersiz origin, olay üretilmedi")
        return nil
      end

      fatal = origin == ErrorEvent::ORIGIN_UNCAUGHT if fatal.nil?
      props = ErrorEvent.properties(error, origin, fatal, app_version || @app_version)
      unless @error_limiter.allow?(props["fingerprint"], @now.call.to_f, rand)
        @logger.debug("feralin: fr_error: hata sınırı ya da örnekleme, olay üretilmedi")
        return nil
      end

      track(ErrorEvent::NAME, props, **options)
    rescue StandardError => e
      # Hata bildirimi uygulamanın hata yolunda çağrılır; kendisi yeni hata fırlatmaz. İleti kullanıcı verisi taşıyabilir.
      @logger.warn("feralin: fr_error üretilemedi (#{e.class})")
      nil
    end

    # Olayı doğrular, UTP v1 biçimine çevirir ve kuyruğa ekler; ağ çağrısı yapmaz. İzin yoksa olay üretilmez ve nil döner.
    # Doğrulama hatasında InvalidEventError, kapalı istemcide ClientClosedError fırlatır.
    # consent: bu olay için izin (çok kullanıcılı sunucuda her isteğin kendi izni).
    def track(event_name, properties = nil, user_id: nil, anonymous_id: nil, session_id: nil, occurred_at: nil,
              context: nil, consent: nil)
      ensure_current_process
      closed, base_consent, opted_out, default_user = @lock.synchronize { [@closed, @consent, @opted_out, @user_id] }
      raise ClientClosedError, "istemci kapatıldı" if closed
      raise InvalidEventError, "consent bir Feralin::Consent örneği olmalı" unless consent.nil? || consent.is_a?(Consent)

      effective = consent || base_consent
      if opted_out || !effective.analytics
        @logger.debug("feralin: izin yok, olay üretilmedi")
        return nil
      end

      name = Events.validate_event_name(event_name)
      props = Events.validate_properties(properties)
      # fr_click yalnız açık reklam ölçümü izniyle gönderilir.
      if props && !effective.advertising
        props.delete(Events::ATTRIBUTION_CLICK_PROPERTY)
        props = nil if props.empty?
      end
      uid = Events.validate_identifier(user_id, "user_id") || default_user
      aid = Events.validate_identifier(anonymous_id, "anonymous_id")
      sid = Events.validate_identifier(session_id, "session_id")
      raise InvalidEventError, "context bir Feralin::Context örneği olmalı" unless context.nil? || context.is_a?(Context)

      event = {
        "event_id" => @ulid.generate,
        "event_name" => name,
        "occurred_at" => Events.format_time(occurred_at || @now.call),
        "platform" => PLATFORM,
        "schema_version" => SCHEMA_VERSION,
        "sdk" => { "name" => SDK_NAME, "version" => SDK_VERSION },
        "consent" => effective.to_h
      }
      event["anonymous_id"] = aid if aid
      event["user_id"] = uid if uid
      event["session_id"] = sid if sid
      event["properties"] = props if props
      if context
        ctx = context.to_h
        event["context"] = ctx unless ctx.empty?
      end

      enqueue(event, serialize(event))
      event
    end

    # Kuyruktaki tüm olayları batch'ler hâlinde gönderir (geri çekilme beklemez; açık çağrı niyet sayılır).
    # Fırlatmaz: RejectedError olayların atıldığını, TemporaryError kuyrukta kaldığını FlushResult#error içinde bildirir.
    def flush
      ensure_current_process
      raise ClientClosedError, "istemci kapatıldı" if @lock.synchronize { @closed }

      perform_flush(nil)
    end

    # Arka plan göndericiyi durdurur ve kalan olayları en fazla timeout saniyede göndermeyi dener.
    # Birden çok çağrı güvenlidir; sonraki çağrılar boş sonuç döner.
    def close(timeout: CLOSE_TIMEOUT)
      ensure_current_process
      already_closed = @lock.synchronize do
        was_closed = @closed
        @closed = true
        was_closed
      end
      return FlushResult.new if already_closed

      stop_thread([timeout, @timeout + 1.0].max)
      perform_flush(monotonic + [timeout, 0.0].max)
    end

    def size
      ensure_current_process
      queue_size
    end
    alias length size

    # Anlık durum (hata ayıklama ve sağlık amaçlı). Anahtar döndürülmez.
    def status
      ensure_current_process
      @lock.synchronize do
        {
          sdk: SDK_NAME,
          version: SDK_VERSION,
          queued: @queue.length,
          dropped: @dropped,
          consent: @consent.to_h,
          user_id: @user_id,
          closed: @closed,
          backoff: @backoff,
          endpoint: @endpoint
        }
      end
    end

    # Varsayılan inspect örnek değişkenlerini, dolayısıyla anahtarı günlüğe taşırdı.
    def inspect
      "#<#{self.class.name} endpoint=#{@endpoint.inspect} queued=#{queue_size} closed=#{@closed}>"
    end

    private

    def parse_collect_url(collect_url)
      text = collect_url.to_s.strip
      begin
        uri = URI.parse(text)
      rescue URI::InvalidURIError
        raise ConfigurationError, "collect_url http veya https şemalı mutlak adres olmalı"
      end
      unless %w[http https].include?(uri.scheme) && uri.host && !uri.host.empty?
        raise ConfigurationError, "collect_url http veya https şemalı mutlak adres olmalı"
      end

      text.sub(%r{/+\z}, "")
    end

    def number_option(name, value)
      number = Float(value, exception: false)
      raise ConfigurationError, "#{name} sayı olmalı" if number.nil? || !number.finite?

      number
    end

    # Yalnız bu sürece ait olan durum: çatallanınca yavruda sıfırdan kurulur.
    def prepare_process_state
      @pid = Process.pid
      @send_lock = Mutex.new # aynı anda tek gönderici (sabit Idempotency-Key)
      @queue = []
      # Sonucu bilinmeyen batch aynı içerik ve aynı Idempotency-Key ile yeniden denenir; sunucu yanıtı yolda
      # kaybolduysa araya giren yeni olaylar anahtarı değiştirip ikinci outbox satırı yazdırmaz.
      @pinned = nil
      @backoff = 0.0
      @backoff_until = 0.0
      # Üst ve yavru aynı rastgele durumdan artırsaydı aynı event_id üretebilirlerdi.
      @ulid = Ulid::Generator.new(-> { (@now.call.to_r * 1000).to_i })
      @wake_lock = Mutex.new
      @wake_signal = ConditionVariable.new
      @wake_pending = false
      @stop = false
      @thread = nil
    end

    def ensure_current_process
      return if @pid == current_pid

      @lock.synchronize do
        return if @pid == current_pid

        prepare_process_state
        @pid = current_pid
        start_thread unless @closed
      end
    end

    def current_pid
      Process.pid
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def serialize(event)
      # Serileştirme kuyruğa eklemeden önce yapılır; bozuk bir olay batch'i zehirleyemez.
      JSON.generate(event)
    rescue JSON::JSONError, EncodingError => e
      raise InvalidEventError, "olay JSON'a dönüştürülemedi: #{e.class}"
    end

    def enqueue(event, raw)
      full = @lock.synchronize do
        raise ClientClosedError, "istemci kapatıldı" if @closed

        @queue << [event["event_id"], raw]
        over = @queue.length - @queue_limit
        if over.positive?
          @queue.shift(over)
          @dropped += over
          @logger.warn("feralin: kuyruk sınırı aşıldı, en eski #{over} olay atıldı")
        end
        @queue.length >= @batch_size
      end
      wake if full && @thread
    end

    def start_thread
      return unless @flush_interval.positive?

      @thread = Thread.new { run_loop }
      @thread.name = "feralin-flush"
    end

    def stop_thread(limit)
      return unless @thread

      @wake_lock.synchronize do
        @stop = true
        @wake_signal.signal
      end
      @thread.join(limit)
    end

    def wake
      @wake_lock.synchronize do
        @wake_pending = true
        @wake_signal.signal
      end
    end

    # Arka plan gönderici: aralık dolunca veya kuyruk batch boyutuna ulaşınca gönderir, geri çekilmeye uyar.
    def run_loop
      loop do
        stopping = @wake_lock.synchronize do
          @wake_signal.wait(@wake_lock, @flush_interval) unless @wake_pending || @stop
          @wake_pending = false
          @stop
        end
        break if stopping
        next if @lock.synchronize { monotonic < @backoff_until }

        begin
          perform_flush(nil)
        rescue StandardError => e
          # Arka plan iş parçacığı ölmesin.
          @logger.warn("feralin: arka plan gönderim hatası: #{e.class}")
        end
      end
    end

    def queue_size
      @lock.synchronize { @queue.length }
    end

    def perform_flush(deadline)
      @send_lock.synchronize do
        sent = accepted = rejected = status = 0
        batch_id = nil
        error = nil
        # Üretici sürekli ekliyorsa döngü sonsuz olmasın: kuyruk sınırı kadar olay + bir tur.
        max_rounds = (@queue_limit / @batch_size) + 2
        max_rounds.times do
          batch = peek
          break if batch.empty?

          timeout = @timeout
          if deadline
            remaining = deadline - monotonic
            unless remaining.positive?
              error = TemporaryError.new("kapanış zaman aşımı; olaylar gönderilemedi", status: 0)
              break
            end
            timeout = [timeout, remaining].min
          end

          result = send_batch(batch, timeout)
          sent += result.sent
          accepted += result.accepted
          rejected += result.rejected
          status = result.status
          batch_id = result.batch_id if result.batch_id
          next unless result.error

          error = result.error
          break
        end
        FlushResult.new(sent: sent, accepted: accepted, rejected: rejected, batch_id: batch_id, status: status,
                        retained: queue_size, error: error)
      end
    end

    def peek
      @lock.synchronize { @pinned || @queue.first(@batch_size) }
    end

    def ack(ids)
      @lock.synchronize do
        @pinned = nil
        @queue.reject! { |item| ids.include?(item[0]) }
      end
    end

    # İstek sürerken izin geri çekildiyse olaylar çoktan silinmiştir, sabitlenmez.
    def pin(batch)
      @lock.synchronize { @pinned = batch unless @opted_out }
    end

    def send_batch(batch, timeout)
      count = batch.length
      event_ids = batch.map(&:first)
      # Olaylar zaten serileştirilmiş; gövde metin birleştirme ile kurulur.
      body = %({"sent_at":#{JSON.generate(Events.format_time(@now.call))},"events":[#{batch.map(&:last).join(",")}]})
      headers = {
        "Content-Type" => "application/json",
        "Accept" => "application/json, application/problem+json",
        "X-Feralin-Project-Key" => @project_key,
        "Idempotency-Key" => Events.idempotency_key_for(event_ids),
        "User-Agent" => "#{SDK_NAME}/#{SDK_VERSION}"
      }

      begin
        status, raw, response_headers = @transport.call(@endpoint, body, headers, timeout)
      rescue DeliveryError => e
        return retained_result(batch, nil, count, e.status, e)
      rescue StandardError => e
        # Özel taşıma katmanının beklenmeyen hatası da uygulamayı düşürmez; sonuç bilinmediğinden olaylar tutulur.
        return retained_result(batch, nil, count, 0, TemporaryError.new("taşıma hatası: #{e.class}", status: 0))
      end

      return accepted_result(event_ids, count, status, raw) if status == 202

      if status >= 400 && status < 500 && status != 429
        ack(event_ids)
        summary = problem_summary(raw)
        @logger.warn("feralin: batch kalıcı olarak reddedildi status=#{status} problem=#{summary}")
        error = RejectedError.new("HTTP #{status}: #{summary}", status: status, detail: summary)
        return FlushResult.new(sent: count, rejected: count, status: status, error: error)
      end

      error = TemporaryError.new("HTTP #{status}; olaylar kuyrukta tutuldu", status: status)
      retained_result(batch, header_value(response_headers, "Retry-After"), count, status, error)
    end

    def retained_result(batch, retry_after, count, status, error)
      pin(batch)
      note_failure(retry_after)
      FlushResult.new(sent: count, retained: count, status: status, error: error)
    end

    def accepted_result(event_ids, count, status, raw)
      body = parse_object(raw)
      ack(event_ids)
      note_success
      accepted = body["accepted"]
      rejected = body["rejected"]
      batch_id = body["batch_id"]
      result = FlushResult.new(
        sent: count,
        accepted: accepted.is_a?(Integer) ? accepted : count,
        rejected: rejected.is_a?(Integer) ? rejected : 0,
        batch_id: batch_id.is_a?(String) ? batch_id : nil,
        status: status
      )
      @logger.debug("feralin: batch kabul edildi batch_id=#{result.batch_id} accepted=#{result.accepted} rejected=#{result.rejected}")
      result
    end

    # Üstel geri çekilme 1 sn - 30 sn; Retry-After verilmişse en az o kadar. Yarım jitter: aynı anda yeniden başlayan
    # süreçler toplayıcıya birlikte yüklenmez.
    def note_failure(retry_after)
      server_wait = Integer(retry_after.to_s.strip, 10, exception: false)
      server_wait = nil unless server_wait&.positive?
      @lock.synchronize do
        delay = [@backoff * 2, MIN_BACKOFF].max
        delay = [delay, server_wait.to_f].max if server_wait
        delay = [delay, MAX_BACKOFF].min
        @backoff = delay
        wait = delay * (0.5 + (rand * 0.5))
        wait = [wait, [server_wait.to_f, MAX_BACKOFF].min].max if server_wait
        @backoff_until = monotonic + wait
      end
    end

    def note_success
      @lock.synchronize do
        @backoff = 0.0
        @backoff_until = 0.0
      end
    end

    def header_value(headers, name)
      lowered = name.downcase
      (headers || {}).each { |key, value| return value if key.to_s.downcase == lowered }
      nil
    end

    def parse_object(raw)
      text = raw.to_s.dup.force_encoding(Encoding::UTF_8)
      parsed = JSON.parse(text.empty? ? "{}" : text)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::JSONError, EncodingError
      {}
    end

    # RFC 7807 gövdesinden kısa, günlüğe yazılabilir özet (ham gövde sızdırılmaz).
    def problem_summary(raw)
      problem = parse_object(raw)
      text = %w[title detail].map { |key| problem[key].to_s.strip }.join(" ").strip
      text.empty? ? "problem+json yok" : text[0, 200]
    end
  end
end
