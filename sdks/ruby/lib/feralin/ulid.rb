# frozen_string_literal: true

require "securerandom"

module Feralin
  # Monotonik ULID üretimi (26 karakter Crockford base32). Web SDK ile aynı düzen:
  # 10 karakter zaman (ms) + 16 adet 5 bitlik rastgele basamak (80 bit).
  module Ulid
    CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
    FORMAT = /\A[0-7][0-9A-HJKMNP-TV-Z]{25}\z/.freeze

    # 26 karakterlik Crockford base32 ULID biçim denetimi (ilk karakter en fazla '7').
    def self.valid?(value)
      value.is_a?(String) && FORMAT.match?(value)
    end

    # Aynı milisaniyede (veya saat geri gittiğinde) son değeri artırarak sıralamayı korur; iş parçacığı güvenlidir.
    class Generator
      def initialize(now_ms = nil)
        @lock = Mutex.new
        @now_ms = now_ms || -> { Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond) }
        @last_ms = -1
        @last_rand = Array.new(16, 0)
      end

      def generate
        @lock.synchronize do
          ms = @now_ms.call
          if ms > @last_ms
            fill_random
          else
            ms = @last_ms
            unless increment
              ms += 1
              fill_random
            end
          end
          @last_ms = ms
          encode(ms)
        end
      end

      private

      def encode(milliseconds)
        out = String.new(capacity: 26)
        remaining = milliseconds
        time_digits = Array.new(10) do
          digit = CROCKFORD[remaining & 31]
          remaining >>= 5
          digit
        end
        time_digits.reverse_each { |digit| out << digit }
        @last_rand.each { |value| out << CROCKFORD[value] }
        out
      end

      def fill_random
        @last_rand = SecureRandom.random_bytes(16).bytes.map { |byte| byte & 31 }
      end

      # Rastgele kısmı base32 düzeninde bir artırır; tüm basamaklar taşarsa false döner.
      def increment
        15.downto(0) do |index|
          if @last_rand[index] < 31
            @last_rand[index] += 1
            return true
          end
          @last_rand[index] = 0
        end
        false
      end
    end
  end
end
