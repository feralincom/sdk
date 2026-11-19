# Yalnız kuyruk şifreleme anahtarı (Keychain) için yerel kod; ayrıntı README'de.
Pod::Spec.new do |s|
  s.name             = 'feralin_flutter'
  s.version          = '0.3.0'
  s.summary          = 'Feralin UTP v1 SDK for Flutter: iOS queue encryption key bridge.'
  s.homepage         = 'https://feralin.com'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = { 'Feralin' => 'support@feralin.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  # AdServices iOS 14.3 ile geldi: zayıf bağlantı, iOS 13 cihazda uygulama açılır ve token istemi nil döner.
  s.weak_frameworks  = 'AdServices'
  s.swift_version    = '5.0'
end
