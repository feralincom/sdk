# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"
require_relative "errors"

module Feralin
  # HTTP taşıma katmanı: yalnız net/http. Testler ve özel ağ yığınları için
  # `transport: ->(url, body, headers, timeout) { [status, body, response_headers] }` ile değiştirilebilir.
  module Transport
    MAX_RESPONSE_BODY = 64 * 1024

    NETWORK_ERRORS = [
      SocketError,
      SystemCallError,
      IOError,
      Timeout::Error,
      Net::ProtocolError,
      Net::HTTPBadResponse,
      Net::HTTPHeaderSyntaxError,
      OpenSSL::SSL::SSLError
    ].freeze

    module_function

    # POST isteği yapar. HTTP hata kodları normal yanıt olarak döner; ağ veya zaman aşımı TemporaryError fırlatır.
    def net_http(url, body, headers, timeout)
      uri = URI.parse(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout
      # Yeniden deneme istemcinin işidir; net/http kendi başına ikinci istek göndermesin.
      http.max_retries = 0

      request = Net::HTTP::Post.new(uri.request_uri, { "Accept-Encoding" => "identity" }.merge(headers))
      request.body = body

      status = 0
      payload = String.new(encoding: Encoding::BINARY)
      response_headers = {}
      http.start do
        http.request(request) do |response|
          status = response.code.to_i
          response.each_header { |name, value| response_headers[name] = value }
          response.read_body do |chunk|
            remaining = MAX_RESPONSE_BODY - payload.bytesize
            payload << chunk.byteslice(0, remaining) if remaining.positive?
          end
        end
      end
      [status, payload, response_headers]
    rescue *NETWORK_ERRORS => e
      raise TemporaryError.new("ağ hatası: #{e.class}: #{e.message}", status: 0)
    end
  end
end
