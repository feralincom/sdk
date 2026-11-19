package com.feralin.flutter

import android.os.Build

/**
 * Uygulamanın emülatörde çalışıp çalışmadığı. Tek bir evet/hayır değeri üretir; Dart yalnız `true` ise ilk açılışa ekler
 * (`device_emulator`). Cihaz kimliği ya da parmak izi üretmez, `Build` alanlarının kendisi Dart'a geçmez.
 *
 * Sezgiseldir ve Android SDK ile aynıdır (sdks/android `EmulatorCheck`): yaygın emülatörlerin bilinen `Build` değerlerine bakar. Kendini
 * gerçek cihaz gibi gösteren özel emülatörü görmez; bu yüzden sunucuda kesin kanıt değil, işaret sayılır.
 */
internal object EmulatorCheck {
    fun read(): Boolean = isEmulator(
        fingerprint = Build.FINGERPRINT,
        model = Build.MODEL,
        manufacturer = Build.MANUFACTURER,
        brand = Build.BRAND,
        device = Build.DEVICE,
        product = Build.PRODUCT,
        hardware = Build.HARDWARE,
    )

    fun isEmulator(fingerprint: String?, model: String?, manufacturer: String?, brand: String?, device: String?, product: String?, hardware: String?): Boolean {
        val print = fingerprint.orEmpty()
        val name = model.orEmpty()
        val item = product.orEmpty()
        val board = hardware.orEmpty()
        return print.startsWith("generic") ||
            print.startsWith("unknown") ||
            print.contains("/sdk_gphone") ||
            print.contains("vbox") ||
            name.contains("google_sdk") ||
            name.contains("Emulator") ||
            name.contains("Android SDK built for") ||
            name.startsWith("sdk_gphone") ||
            manufacturer.orEmpty().contains("Genymotion") ||
            (brand.orEmpty().startsWith("generic") && device.orEmpty().startsWith("generic")) ||
            item == "google_sdk" ||
            item.startsWith("sdk_gphone") ||
            item.startsWith("sdk_google") ||
            item.contains("emulator") ||
            item.contains("simulator") ||
            item.startsWith("vbox") ||
            board == "goldfish" ||
            board == "ranchu" ||
            board.contains("vbox")
    }
}
