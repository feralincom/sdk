# frozen_string_literal: true

# README'deki yol: Railtie bu dosyadan sonra çalışmazsa çözücü okunmaz ve izinli istek testi kalır.
Rails.application.config.feralin.consent_resolver = lambda do |env|
  Feralin::Consent.new(analytics: env["HTTP_X_ANALITIK"] == "1")
end
