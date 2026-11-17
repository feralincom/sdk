# frozen_string_literal: true

require_relative "client"
require_relative "rack"

module Feralin
  # Denetleyicide `feralin.track("order_completed", { order_id: order.public_id })`.
  module ControllerHelpers
    private

    def feralin
      request.env[Rack::ENV_KEY]
    end
  end

  # Rails bütünleşmesi. Yalnız Rails yüklüyse lib/feralin.rb tarafından yüklenir; gem'in bağımlılığı değildir.
  #
  #   # config/application.rb veya config/initializers/feralin.rb
  #   config.feralin.consent_resolver = ->(env) { Feralin::Consent.new(analytics: env["HTTP_X_ANALITIK"] == "1") }
  #
  # Anahtar ve adres FERALIN_PROJECT_KEY ve FERALIN_COLLECT_URL ortam değişkenlerinden veya config.feralin üzerinden gelir.
  class Railtie < ::Rails::Railtie
    CLIENT_OPTIONS = %i[flush_interval batch_size queue_limit timeout consent].freeze

    config.feralin = ActiveSupport::OrderedOptions.new

    # config/initializers içindeki ayarlar okunsun diye onlardan sonra, ara katman yığını kurulmadan önce çalışır.
    initializer "feralin.setup", after: :load_config_initializers do |app|
      settings = app.config.feralin
      Railtie.start_client(settings) unless Feralin.client
      app.middleware.use(Rack::Middleware,
                         consent: settings.consent_resolver,
                         flush_after_request: settings.flush_after_request == true,
                         logger: ::Rails.logger)
    end

    initializer "feralin.controller_helpers" do
      ActiveSupport.on_load(:action_controller) { include ControllerHelpers }
    end

    def self.start_client(settings)
      key = settings.project_key || ENV["FERALIN_PROJECT_KEY"]
      url = settings.collect_url || ENV["FERALIN_COLLECT_URL"]
      if key.to_s.empty? || url.to_s.empty?
        # Geliştirme ortamında uygulama açılmaya devam eder; olay üretilmez ve bu günlükte görünür.
        ::Rails.logger&.info("feralin: proje anahtarı veya toplayıcı adresi yok, olay gönderilmeyecek")
        return
      end

      options = CLIENT_OPTIONS.each_with_object({}) do |name, out|
        value = settings[name]
        out[name] = value unless value.nil?
      end
      client = Client.new(key, url, logger: ::Rails.logger, **options)
      Feralin.client = client
      at_exit { client.close }
    end
  end
end
