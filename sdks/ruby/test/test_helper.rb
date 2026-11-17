# frozen_string_literal: true

require "json"
require "socket"
require "timeout"
require "minitest/autorun"
require "feralin"

TEST_KEY = "pk_live_0123456789abcdef0123456789abcdef"
SCHEMA_PATH = File.expand_path("../../../packages/schemas/utp/v1/event.schema.json", __dir__)
OCCURRED_AT_FORMAT = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/.freeze

# Yanıtları önceden yazılabilen gerçek yerel HTTP sunucusu (TCPServer). `script` tükenince 202 onay döner.
class FakeCollector
  attr_accessor :script

  def initialize(script = [])
    @lock = Mutex.new
    @requests = []
    @script = script
    @received = Queue.new
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @closed = false
    @thread = Thread.new { accept_loop }
  end

  def url
    "http://127.0.0.1:#{@port}"
  end

  def count
    @lock.synchronize { @requests.length }
  end

  def request(index)
    @lock.synchronize { @requests[index] }
  end

  def wait(limit = 3.0)
    Timeout.timeout(limit) { @received.pop }
    true
  rescue Timeout::Error
    false
  end

  def close
    return if @closed

    @closed = true
    @server.close
    @thread.join(1)
  end

  private

  def accept_loop
    loop { Thread.new(@server.accept) { |socket| serve(socket) } }
  rescue IOError, SystemCallError
    nil
  end

  def serve(socket)
    request_line = socket.gets
    return unless request_line

    path = request_line.split[1]
    headers = {}
    while (line = socket.gets) && line != "\r\n"
      name, value = line.chomp.split(": ", 2)
      headers[name.downcase] = value
    end
    raw = socket.read(headers.fetch("content-length", "0").to_i).to_s.force_encoding(Encoding::UTF_8)
    if path == "/v1/batch"
      respond(socket, *record(headers, raw))
    else
      respond(socket, 404, "{}", {})
    end
    @received << true
  rescue IOError, SystemCallError
    nil
  ensure
    socket.close
  end

  def record(headers, raw)
    body = JSON.parse(raw)
    @lock.synchronize do
      @requests << { headers: headers, body: body }
      next @script.shift if @script.any?

      accepted = body.fetch("events", []).length
      [202, JSON.generate({ batch_id: "01TESTBATCH0000000000000000", accepted: accepted, rejected: 0 }), {}]
    end
  end

  def respond(socket, status, payload, extra)
    lines = ["HTTP/1.1 #{status} Test", "Content-Type: application/json", "Content-Length: #{payload.bytesize}", "Connection: close"]
    extra.each { |name, value| lines << "#{name}: #{value}" }
    socket.write("#{lines.join("\r\n")}\r\n\r\n#{payload}")
  end
end

# Günlüğü bellekte tutan Logger arayüzü.
class MemoryLogger
  attr_reader :lines

  def initialize
    @lines = []
  end

  def debug(message = nil)
    @lines << message.to_s
  end

  def warn(message = nil)
    @lines << message.to_s
  end
end

class ClientTestCase < Minitest::Test
  def setup
    @collector = FakeCollector.new
    @clients = []
  end

  def teardown
    @clients.each { |client| client.close(timeout: 1.0) }
    @collector.close
  end

  def make_client(script: nil, **options)
    @collector.script = script if script
    options[:consent] = Feralin::Consent.new(analytics: true) unless options.key?(:consent)
    options[:flush_interval] = 0 unless options.key?(:flush_interval) # arka plan kapalı; testler flush ve close ile kontrol eder
    options[:logger] = MemoryLogger.new unless options.key?(:logger)
    client = Feralin::Client.new(TEST_KEY, @collector.url, **options)
    @clients << client
    client
  end

  # Tel üzerindeki olayın UTP v1 kurallarına uyduğunu denetler (json-schema bağımlılığı yok).
  def assert_wire_event(wire)
    %w[event_id event_name occurred_at platform schema_version consent].each do |key|
      assert wire.key?(key), "zorunlu alan eksik: #{key}"
    end
    %w[tenant_id project_id verified source_ip ip].each do |key|
      refute wire.key?(key), "istemciden gönderilmemesi gereken alan var: #{key}"
    end
    assert Feralin::Ulid.valid?(wire["event_id"]), wire["event_id"]
    assert_equal "ruby", wire["platform"]
    assert_equal 1, wire["schema_version"]
    assert_equal({ "name" => "feralin-ruby", "version" => Feralin::VERSION }, wire["sdk"])
    assert_match OCCURRED_AT_FORMAT, wire["occurred_at"]
    assert_equal true, wire.dig("consent", "analytics")
    return unless File.exist?(SCHEMA_PATH)

    schema = JSON.parse(File.read(SCHEMA_PATH, encoding: "utf-8"))
    wire.each_key { |key| assert schema["properties"].key?(key), "şemada olmayan alan gönderildi: #{key}" }
    assert_includes schema.dig("properties", "platform", "enum"), wire["platform"]
  end
end
