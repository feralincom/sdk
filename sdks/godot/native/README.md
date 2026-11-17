# Godot yerel köprüleri (derlenmedi)

Bu dizindeki kaynaklar Godot eklentisinin platforma özgü kısımlarıdır. **Hiçbiri derlenmedi ve cihazda sınanmadı**: bu makinede Godot, Android araç zinciri ve macOS yoktur. Köprüler yoksa SDK çalışır; yalnız şu özellikler kapanır: kuyruk anahtarı Keystore/Keychain yerine dosyada kalır (`local_file`), Play Install Referrer okunmaz, AdServices token'ı alınmaz.

| Köprü | Dosya | GDScript tarafı |
|---|---|---|
| Android: Keystore, Play Install Referrer | `android/FeralinAndroidPlugin.java` | `Engine.get_singleton("FeralinAndroid")` |
| iOS: Keychain, AdServices, ATT | `ios/feralin_ios.mm` | `Engine.get_singleton("FeralinIOS")` |

## Android

1. Godot 4.2+ Android eklenti şablonunu (`GodotPlugin`) kullanan bir kitaplık modülü oluşturun; `FeralinAndroidPlugin.java` dosyasını ekleyin.
2. Bağımlılık: `com.android.installreferrer:installreferrer:2.2`.
3. `AndroidManifest.xml` içine `<meta-data android:name="org.godotengine.plugin.v2.FeralinAndroid" android:value="com.feralin.godot.FeralinAndroidPlugin"/>`.
4. Dışa aktarma ön ayarında Gradle derlemesini ve eklentiyi etkinleştirin.

## iOS

`feralin_ios.mm`, Godot iOS eklenti şablonu (`.gdip` + statik kitaplık) içinde derlenir; `Security` çerçevesi bağlanmalıdır. AdServices ve AppTrackingTransparency çalışma zamanında yüklenir. `PackedByteArray` ve `String` türleri Godot başlıklarına bağlıdır; şablon sürümüne göre başlık yolları değişebilir.

## Dürüst durum

Registry (Godot Asset Library) yayını `BLOCKED_EXTERNAL`: hesap ve herkese açık Git deposu gerekir.
