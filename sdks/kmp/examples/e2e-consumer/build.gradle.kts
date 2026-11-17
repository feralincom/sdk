// Temiz tüketici: scripts/sdk-e2e/targets/kmp.mjs boş dizine kopyalar; paket yalnız yerel Maven dizininden gelir.
plugins {
    kotlin("jvm") version "2.2.20"
    application
}

repositories {
    maven { url = uri(providers.gradleProperty("feralinLocalRepo").get()) }
    mavenCentral()
}

dependencies {
    implementation("com.feralin:feralin-kmp:${providers.gradleProperty("feralinVersion").get()}")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
}

application {
    mainClass.set("MainKt")
}
