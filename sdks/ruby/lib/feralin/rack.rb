# frozen_string_literal: true

require_relative "errors"
require_relative "events"

module Feralin
  # Rack bütünleşmesi. Yalnız Rack sözleşmesini (env + call) kullanır; rack gem'ini yüklemez.
  # Otomatik olay üretmez: istek yolu ve sorgusu kişisel veri taşıyabilir, hangi olayın gideceğine uygulama karar verir.
  module Rack
    ENV_KEY = "feralin.tracker"

    # İsteğe bağlı olay arayüzü. Kimlik ve izin bu nesnede yaşar: paylaşılan istemcide tutulsalardı eşzamanlı
    # isteklerde bir kullanıcının kimliği başka kullanıcının olayına yazılabilirdi.
    class Tracker
      def initialize(client, env, consent_resolver, logger: nil)
        @client = client
        @env = env
        @consent_resolver = consent_resolver
        @logger = logger
        @user_id = nil
        @consent = nil
      end

      # İstemci yoksa (ör. anahtar tanımsız) olay üretilmez ve nil döner.
      def track(event_name, properties = nil, user_id: nil, consent: nil, **options)
        return nil unless @client

        @client.track(event_name, properties, user_id: user_id || @user_id, consent: consent || current_consent, **options)
      end

      # Client#track_revenue; bu isteğin kimliği ve izni eklenir.
      def track_revenue(transaction_id, amount_minor, currency, user_id: nil, consent: nil, **options)
        return nil unless @client

        @client.track_revenue(transaction_id, amount_minor, currency,
                              user_id: user_id || @user_id, consent: consent || current_consent, **options)
      end

      # Client#group; bu isteğin kimliği ve izni eklenir.
      def group(group_id, traits = nil, user_id: nil, consent: nil, **options)
        return nil unless @client

        @client.group(group_id, traits, user_id: user_id || @user_id, consent: consent || current_consent, **options)
      end

      # Client#set_user_properties; bu isteğin kimliği ve izni eklenir.
      def set_user_properties(properties, user_id: nil, consent: nil, **options)
        return nil unless @client

        @client.set_user_properties(properties, user_id: user_id || @user_id, consent: consent || current_consent, **options)
      end

      # Client#capture_error; bu isteğin kimliği ve izni eklenir. Fırlatmaz.
      def capture_error(error, user_id: nil, consent: nil, **options)
        return nil unless @client

        @client.capture_error(error, user_id: user_id || @user_id, consent: consent || current_consent, **options)
      end

      # Yalnız bu isteğin sonraki olayları için user_id; nil kaldırır.
      def identify(user_id)
        @user_id = Events.validate_identifier(user_id, "user_id")
        nil
      end

      # Yalnız bu isteğin sonraki olayları için izin (ör. kullanıcı bu istekte izin verdi).
      def set_consent(consent)
        raise InvalidEventError, "consent bir Feralin::Consent örneği olmalı" unless consent.is_a?(Consent)

        @consent = consent
        nil
      end

      def flush
        @client ? @client.flush : FlushResult.new
      end

      def inspect
        "#<#{self.class.name} client=#{@client.inspect}>"
      end

      private

      # Çözücü yoksa nil döner ve istemcinin varsayılan izni geçerli olur.
      def current_consent
        return @consent if @consent
        return nil unless @consent_resolver

        @consent = resolve_consent
      end

      # Çözücü hata verir veya izin dönmezse izin yok sayılır. Hata iletisi kullanıcı verisi taşıyabileceğinden
      # günlüğe yalnız sınıf adı yazılır.
      def resolve_consent
        value = @consent_resolver.call(@env)
        return value if value.is_a?(Consent)

        warn_logger("feralin: izin çözücüsü Feralin::Consent dönmedi (#{value.class}); izin yok sayıldı") unless value.nil?
        Consent.new
      rescue StandardError => e
        warn_logger("feralin: izin çözücüsü hata verdi (#{e.class}); izin yok sayıldı")
        Consent.new
      end

      def warn_logger(message)
        @logger ? @logger.warn(message) : $stderr.puts(message)
      end
    end

    # Her isteğe env["feralin.tracker"] ekler.
    #
    #   use Feralin::Rack::Middleware,
    #       client: client,
    #       consent: ->(env) { Feralin::Consent.new(analytics: env["HTTP_COOKIE"].to_s.include?("analitik=1")) }
    #
    # client verilmezse Feralin.client kullanılır. flush_after_request: arka plan göndericisi kapalıyken (flush_interval: 0)
    # olayları yanıttan sonra gönderir; sunucu desteklemiyorsa yanıttan önce, istek süresine eklenerek gönderir.
    class Middleware
      def initialize(app, client: nil, consent: nil, flush_after_request: false, logger: nil)
        raise ConfigurationError, "consent çağrılabilir olmalı" unless consent.nil? || consent.respond_to?(:call)

        @app = app
        @client = client
        @consent = consent
        @flush_after_request = flush_after_request
        @logger = logger
      end

      def call(env)
        client = @client || Feralin.client
        env[ENV_KEY] = Tracker.new(client, env, @consent, logger: @logger)
        begin
          @app.call(env)
        ensure
          schedule_flush(env, client) if @flush_after_request && client
        end
      end

      private

      def schedule_flush(env, client)
        finished = env["rack.response_finished"]
        finished = env["rack.after_reply"] unless finished.is_a?(Array)
        if finished.is_a?(Array)
          finished << proc { |*| safe_flush(client) }
        else
          safe_flush(client)
        end
      end

      # Gönderim sonucu uygulamayı düşürmez; kapanış sırasında gelen istek de hata vermez.
      def safe_flush(client)
        client.flush
      rescue ClientClosedError
        nil
      end
    end
  end
end
