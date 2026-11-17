# frozen_string_literal: true

require_relative "lib/feralin/version"

Gem::Specification.new do |spec|
  spec.name = "feralin"
  spec.version = Feralin::VERSION
  spec.authors = ["Feralin"]
  spec.summary = "Feralin UTP v1 sunucu SDK'sı: Ruby istemcisi, Rack middleware ve Rails Railtie"
  spec.description = "Feralin toplayıcısına izin öncelikli, bellek içi kuyruklu ve idempotent olay gönderir. " \
                     "Yalnız standart kütüphane kullanır; çalışma zamanı bağımlılığı yoktur."
  spec.license = "MIT"
  spec.homepage = "https://feralin.com"
  spec.required_ruby_version = ">= 3.0"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/feralincom/sdk"
  spec.metadata["changelog_uri"] = "https://github.com/feralincom/sdk/blob/main/sdks/ruby/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "https://github.com/feralincom/sdk/blob/main/docs/sdk/ruby.md"

  # Yol, geçerli dizinden bağımsız olsun diye gemspec'in dizinine göre çözülür.
  root = __dir__
  spec.files = Dir.glob("lib/**/*.rb", base: root) + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ["lib"]
end
