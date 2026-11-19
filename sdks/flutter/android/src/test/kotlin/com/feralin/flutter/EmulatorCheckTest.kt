package com.feralin.flutter

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class EmulatorCheckTest {
    @Test
    fun yayginEmulatorlerTaninir() {
        // Android Studio emülatörü (API 34, Google API'li görüntü).
        assertTrue(EmulatorCheck.isEmulator("google/sdk_gphone64_x86_64/emu64xa:14/UE1A.230829.036/11228894:userdebug/dev-keys", "sdk_gphone64_x86_64", "Google", "google", "emu64xa", "sdk_gphone64_x86_64", "ranchu"))
        // Eski AOSP emülatörü.
        assertTrue(EmulatorCheck.isEmulator("generic/sdk/generic:4.4.2/KK/eng.build:eng/test-keys", "Android SDK built for x86", "unknown", "generic", "generic", "sdk", "goldfish"))
        assertTrue(EmulatorCheck.isEmulator("x", "Custom Phone", "Genymotion", "x", "x", "vbox86p", "vbox86"))
    }

    @Test
    fun gercekCihazEmulatorSayilmaz() {
        assertFalse(EmulatorCheck.isEmulator("samsung/a54xnaeea/a54x:14/UP1A.231005.007/A546BXXS7CXE4:user/release-keys", "SM-A546B", "samsung", "samsung", "a54x", "a54xnaeea", "s5e8835"))
        assertFalse(EmulatorCheck.isEmulator("google/husky/husky:14/AP1A.240405.002/11480754:user/release-keys", "Pixel 8 Pro", "Google", "google", "husky", "husky", "husky"))
        assertFalse(EmulatorCheck.isEmulator(null, null, null, null, null, null, null))
    }
}
