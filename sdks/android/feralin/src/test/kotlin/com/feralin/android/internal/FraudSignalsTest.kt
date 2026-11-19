package com.feralin.android.internal

import com.feralin.android.SigningKey
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FraudSignalsTest {
    @Test
    fun imzaSunucununUrettigiDegerleAyni() {
        // Beklenen değer sunucu uygulamasıyla (Node, HMAC-SHA256) aynı girdiden hesaplandı.
        assertEquals(
            "v1.sgn_0123456789abcdef.1795000000.6f939a78369f2fb6cb3aa73fcc800d17e783292a926b865e2becac05f6b6def7",
            EventSigner.sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-1", "app_first_open", "anon-1"),
        )
    }

    @Test
    fun imzaOlayaVeKurulumaBaglidir() {
        val base = EventSigner.sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-1", "app_first_open", "anon-1")
        assertFalse(base == EventSigner.sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-2", "app_first_open", "anon-1"))
        assertFalse(base == EventSigner.sign("sgn_0123456789abcdef", "fsk_gizli", 1_795_000_000L, "evt-1", "app_first_open", "anon-2"))
        assertFalse(base == EventSigner.sign("sgn_0123456789abcdef", "fsk_baska", 1_795_000_000L, "evt-1", "app_first_open", "anon-1"))
    }

    @Test
    fun imzaAnahtariBicimiDenetlenirVeDegeriYazilmaz() {
        assertNull(SigningKey("sgn_0123456789abcdef", "fsk_gizli_anahtar_degeri").validationError())
        assertNotNull(SigningKey("anahtar", "fsk_gizli_anahtar_degeri").validationError())
        assertNotNull(SigningKey("sgn_0123456789abcdef", "kisa").validationError())
        assertFalse(SigningKey("sgn_0123456789abcdef", "fsk_gizli_anahtar_degeri").toString().contains("fsk_"))
    }

    @Test
    fun yayginEmulatorlerTaninir() {
        // Android Studio emülatörü (API 34, Google API'li görüntü).
        assertTrue(EmulatorCheck.isEmulator("google/sdk_gphone64_x86_64/emu64xa:14/UE1A.230829.036/11228894:userdebug/dev-keys", "sdk_gphone64_x86_64", "Google", "google", "emu64xa", "sdk_gphone64_x86_64", "ranchu"))
        // Eski AOSP emülatörü.
        assertTrue(EmulatorCheck.isEmulator("generic/sdk/generic:4.4.2/KK/eng.build:eng/test-keys", "Android SDK built for x86", "unknown", "generic", "generic", "sdk", "goldfish"))
        assertTrue(EmulatorCheck.isEmulator("x", "Custom Phone", "Genymotion", "x", "x", "vbox86p", "vbox86"))
    }

    @Test
    fun rootSinamaAnahtariVeSuDosyasiylaTaninir() {
        assertTrue(RootCheck.isRooted("test-keys") { false })
        assertTrue(RootCheck.isRooted("release-keys") { it == "/system/xbin/su" })
        assertFalse(RootCheck.isRooted("release-keys") { false })
        assertFalse(RootCheck.isRooted(null) { false })
        // Dosya sistemi erişimi reddedilirse root sayılmaz, hata yükselmez.
        assertFalse(RootCheck.isRooted("release-keys") { throw SecurityException("erişim yok") })
    }

    @Test
    fun gercekCihazEmulatorSayilmaz() {
        assertFalse(EmulatorCheck.isEmulator("samsung/a54xnaeea/a54x:14/UP1A.231005.007/A546BXXS7CXE4:user/release-keys", "SM-A546B", "samsung", "samsung", "a54x", "a54xnaeea", "s5e8835"))
        assertFalse(EmulatorCheck.isEmulator("google/husky/husky:14/AP1A.240405.002/11480754:user/release-keys", "Pixel 8 Pro", "Google", "google", "husky", "husky", "husky"))
        assertFalse(EmulatorCheck.isEmulator(null, null, null, null, null, null, null))
    }
}
