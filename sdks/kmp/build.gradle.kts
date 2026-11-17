import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// Sürümler sdks/android ile aynı araç zinciri: Kotlin 2.2.20, AGP 8.13.2. Ktor 3.3 bu Kotlin sürümüyle uyumlu derlenir.
plugins {
    kotlin("multiplatform") version "2.2.20"
    id("com.android.library") version "8.13.2" apply false
    `maven-publish`
}

val feralinVersion = providers.gradleProperty("feralinVersion").get()
val ktorVersion = "3.3.3"
val coroutinesVersion = "1.10.2"
val serializationVersion = "1.9.0"

group = "com.feralin"
version = feralinVersion

repositories {
    google()
    mavenCentral()
}

// Android SDK yoksa Android hedefi kurulmaz; yalnız JDK olan makinede jvm hedefi yine derlenir.
val androidSdkAvailable = System.getenv("ANDROID_HOME") != null ||
    System.getenv("ANDROID_SDK_ROOT") != null ||
    file("local.properties").exists()

if (androidSdkAvailable) {
    apply(plugin = "com.android.library")
    extensions.configure<com.android.build.gradle.LibraryExtension>("android") {
        namespace = "com.feralin.kmp"
        compileSdk = 36
        defaultConfig {
            minSdk = 24
        }
        compileOptions {
            sourceCompatibility = JavaVersion.VERSION_11
            targetCompatibility = JavaVersion.VERSION_11
        }
    }
}

kotlin {
    jvm {
        compilerOptions { jvmTarget.set(JvmTarget.JVM_11) }
    }
    if (androidSdkAvailable) {
        androidTarget {
            compilerOptions { jvmTarget.set(JvmTarget.JVM_11) }
            publishLibraryVariants("release")
        }
    }
    iosArm64()
    iosSimulatorArm64()
    iosX64()

    sourceSets {
        commonMain.dependencies {
            implementation("io.ktor:ktor-client-core:$ktorVersion")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:$coroutinesVersion")
            api("org.jetbrains.kotlinx:kotlinx-serialization-json:$serializationVersion")
        }
        commonTest.dependencies {
            implementation(kotlin("test"))
            implementation("io.ktor:ktor-client-mock:$ktorVersion")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:$coroutinesVersion")
        }
        jvmMain.dependencies {
            implementation("io.ktor:ktor-client-cio:$ktorVersion")
        }
        iosMain.dependencies {
            implementation("io.ktor:ktor-client-darwin:$ktorVersion")
        }
        if (androidSdkAvailable) {
            androidMain.dependencies {
                implementation("io.ktor:ktor-client-okhttp:$ktorVersion")
            }
        }
    }
}

publishing {
    repositories {
        // Yalnız uçtan uca test: registry değil, verilen dizine yazar. Maven Central yayını yoktur.
        providers.gradleProperty("feralinLocalRepo").orNull?.let { path ->
            maven {
                name = "LocalE2E"
                url = uri(path)
            }
        }
        // Paket dry-run'ı (scripts/sdk-dry-run/run.mjs): aynı şekilde yalnız yerel dizine yazar.
        providers.gradleProperty("feralinVendorRepo").orNull?.let { path ->
            maven {
                name = "LocalVendor"
                url = uri(path)
            }
        }
    }
}
