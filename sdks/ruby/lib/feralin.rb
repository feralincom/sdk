# frozen_string_literal: true

require_relative "feralin/version"
require_relative "feralin/errors"
require_relative "feralin/ulid"
require_relative "feralin/events"
require_relative "feralin/transport"
require_relative "feralin/client"
require_relative "feralin/rack"

# Feralin UTP v1 sunucu SDK'sı.
module Feralin
  class << self
    # Rack middleware'in ve Railtie'nin paylaştığı süreç geneli istemci.
    attr_accessor :client
  end
end

require_relative "feralin/railtie" if defined?(::Rails::Railtie)
