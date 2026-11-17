package com.feralin.android.internal

import android.app.Activity
import android.app.Application
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment

@RunWith(RobolectricTestRunner::class)
class AppLifecycleTrackerTest {
    private val events = ArrayList<String>()
    private val links = ArrayList<String>()

    @Before
    fun setUp() {
        val app = RuntimeEnvironment.getApplication() as Application
        app.registerActivityLifecycleCallbacks(
            AppLifecycleTracker(
                onForeground = { events.add("fg") },
                onBackground = { events.add("bg") },
                onIntent = { intent -> IntentLinks.consume(intent)?.let { links.add(it) } },
                captureLinks = true,
            ),
        )
    }

    private fun viewIntent(url: String) = Intent(Intent.ACTION_VIEW, Uri.parse(url))

    @Test
    fun onVeArkaPlanGecisleri() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        assertEquals(listOf("fg"), events)
        controller.pause().stop()
        assertEquals(listOf("fg", "bg"), events)
        controller.start().resume()
        assertEquals(listOf("fg", "bg", "fg"), events)
    }

    @Test
    fun etkinlikGecisindeArkaPlanSayilmaz() {
        val a = Robolectric.buildActivity(Activity::class.java).setup()
        a.pause()
        val b = Robolectric.buildActivity(Activity::class.java).setup()
        a.stop()
        assertEquals(listOf("fg"), events)
        b.pause().stop()
        assertEquals(listOf("fg", "bg"), events)
    }

    @Test
    fun yapilandirmaDegisiminiArkaPlanSaymaz() {
        val controller = Robolectric.buildActivity(Activity::class.java).setup()
        val rotated = Configuration(controller.get().resources.configuration).apply {
            orientation = if (orientation == Configuration.ORIENTATION_PORTRAIT) {
                Configuration.ORIENTATION_LANDSCAPE
            } else {
                Configuration.ORIENTATION_PORTRAIT
            }
        }
        controller.configurationChange(rotated)
        assertEquals(listOf("fg"), events)
    }

    @Test
    fun appLinkBirKezYakalanir() {
        val controller = Robolectric.buildActivity(Activity::class.java, viewIntent("https://go.example.com/o?fr_click=c1")).setup()
        assertEquals(listOf("https://go.example.com/o?fr_click=c1"), links)
        controller.pause().stop().start().resume()
        assertEquals("aynı niyet ikinci kez sayılmaz", 1, links.size)
    }

    @Test
    fun yeniNiyetIkinciKezSayilir() {
        val controller = Robolectric.buildActivity(Activity::class.java, viewIntent("https://go.example.com/1")).setup()
        controller.pause()
        controller.get().intent = viewIntent("https://go.example.com/2")
        controller.resume()
        assertEquals(listOf("https://go.example.com/1", "https://go.example.com/2"), links)
    }

    @Test
    fun durumGeriYuklemesindeSayilmaz() {
        Robolectric.buildActivity(Activity::class.java, viewIntent("https://go.example.com/1"))
            .setup(Bundle())
        assertEquals(emptyList<String>(), links)
    }

    @Test
    fun gecmistenAcilisVeVieDisiNiyetlerSayilmaz() {
        val history = viewIntent("https://go.example.com/1").addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)
        assertNull(IntentLinks.consume(history))
        assertNull(IntentLinks.consume(Intent(Intent.ACTION_MAIN)))
        val intent = viewIntent("https://go.example.com/1")
        assertEquals("https://go.example.com/1", IntentLinks.consume(intent))
        assertNull(IntentLinks.consume(intent))
    }
}
