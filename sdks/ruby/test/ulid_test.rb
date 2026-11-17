# frozen_string_literal: true

require "test_helper"

class UlidTest < Minitest::Test
  ULID_FORMAT = /\A[0-7][0-9A-HJKMNP-TV-Z]{25}\z/.freeze
  FIXED_MS = 1_762_164_000_000 # 2025-11-03T10:00:00Z

  def test_format
    generator = Feralin::Ulid::Generator.new
    1000.times do
      value = generator.generate
      assert_match ULID_FORMAT, value
      assert Feralin::Ulid.valid?(value)
    end
    ["", "01ARZ3NDEKTSV4RRFFQ69G5FAV1", "01ARZ3NDEKTSV4RRFFQ69G5FA", "01ARZ3NDEKTSV4RRFFQ69G5FAI",
     "81ARZ3NDEKTSV4RRFFQ69G5FAV", "01ARZ3NDEKTSV4RRFFQ69G5FAV\n", nil].each do |bad|
      refute Feralin::Ulid.valid?(bad), bad.inspect
    end
  end

  def test_timestamp_prefix
    value = Feralin::Ulid::Generator.new(-> { FIXED_MS }).generate
    decoded = value[0, 10].each_char.reduce(0) { |sum, char| (sum * 32) + Feralin::Ulid::CROCKFORD.index(char) }
    assert_equal FIXED_MS, decoded
  end

  def test_monotonic_within_same_millisecond
    generator = Feralin::Ulid::Generator.new(-> { FIXED_MS })
    ids = Array.new(5000) { generator.generate }
    ids.each_cons(2) do |previous, current|
      assert_operator previous, :<, current
      assert_equal previous[0, 10], current[0, 10]
    end
  end

  def test_monotonic_when_clock_goes_backwards
    clock = FIXED_MS
    generator = Feralin::Ulid::Generator.new(-> { clock })
    first = generator.generate
    clock -= 10_000
    assert_operator generator.generate, :>, first
  end

  def test_random_overflow_advances_time
    generator = Feralin::Ulid::Generator.new(-> { FIXED_MS })
    first = generator.generate
    generator.instance_variable_set(:@last_rand, Array.new(16, 31)) # rastgele kısım dolu: bir sonraki artış taşar
    following = generator.generate
    assert_operator following, :>, first
    refute_equal first[0, 10], following[0, 10]
  end

  def test_concurrent_unique
    generator = Feralin::Ulid::Generator.new
    results = Array.new(8) { Thread.new { Array.new(500) { generator.generate } } }.flat_map(&:value)
    assert_equal results.length, results.uniq.length
  end
end
