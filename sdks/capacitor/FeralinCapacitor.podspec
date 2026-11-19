# CocoaPods ile kurulan Capacitor iOS projeleri için. Swift Package kurulumu Package.swift dosyasındadır. Feralin Swift çekirdeği
# (ios/Sources/Feralin, scripts/vendor.mjs kopyası) bu podda eklentiyle aynı modülde derlenir.
require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name = 'FeralinCapacitor'
  s.version = package['version']
  s.summary = package['description']
  s.license = package['license']
  s.homepage = 'https://feralin.com'
  s.author = 'Feralin'
  s.source = { :git => 'https://github.com/feralincom/sdk.git', :tag => s.version.to_s }
  s.source_files = 'ios/Sources/**/*.swift'
  s.resource_bundles = { 'FeralinPrivacy' => ['ios/Sources/Feralin/Resources/PrivacyInfo.xcprivacy'] }
  s.ios.deployment_target = '15.0'
  s.dependency 'Capacitor'
  s.swift_version = '5.9'
end
