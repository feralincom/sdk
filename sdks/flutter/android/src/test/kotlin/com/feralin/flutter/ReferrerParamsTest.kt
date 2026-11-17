package com.feralin.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReferrerParamsTest {
    @Test
    fun yalnizIzinListesiGecer() {
        val params = ReferrerParams.parse("fr_click=c1&utm_source=ads&gclid=x&email=a%40b.c&utm_foo=y")
        assertEquals(mapOf("fr_click" to "c1", "utm_source" to "ads"), params)
    }

    @Test
    fun cifteKodlamaVeBozukGirdi() {
        assertEquals(mapOf("fr_click" to "c1"), ReferrerParams.parse("fr_click%3Dc1"))
        assertTrue(ReferrerParams.parse(null).isEmpty())
        assertTrue(ReferrerParams.parse("").isEmpty())
        assertTrue(ReferrerParams.parse("fr_click=%ZZ&=x&utm_source=").isEmpty())
    }

    @Test
    fun ertelenmisYolDartaGecer() {
        // Yerel süzgeç atarsa Flutter'da teslim hiç çalışmaz: değer doğrulaması Dart'tadır.
        assertEquals(mapOf("fr_click" to "c1", "fr_dl" to "/urun/42"), ReferrerParams.parse("fr_click=c1&fr_dl=%2Furun%2F42"))
    }

    @Test
    fun ilkDegerGecerli() {
        assertEquals(mapOf("utm_source" to "a"), ReferrerParams.parse("utm_source=a&utm_source=b"))
    }
}
