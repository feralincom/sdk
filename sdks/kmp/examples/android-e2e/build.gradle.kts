// KMP SDK'nın Android hedefi (Ktor OkHttp motoru) emülatörde gerçek toplayıcıya. Sürümler sdks/kmp ile aynı araç zinciri.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application") version "8.13.2"
    id("org.jetbrains.kotlin.android") version "2.2.20"
}

// Değerler sır değildir: emülatörden ana makinedeki yerel toplayıcıya (10.0.2.2) test anahtarıyla bağlanır.
val e2eCollectUrl = providers.gradleProperty("feE2eCollectUrl").getOrElse("http://10.0.2.2:4762")
val e2eProjectKey = providers.gradleProperty("feE2eKey").getOrElse("pk_test_sdk_kmp_android_0001")

android {
    namespace = "com.feralin.kmpe2e"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.feralin.kmpe2e"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "COLLECT_URL", "\"$e2eCollectUrl\"")
        buildConfigField("String", "PROJECT_KEY", "\"$e2eProjectKey\"")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            // R8 altında da çalıştığı sınanır. Yayınlanmaz: makinenin debug anahtarıyla imzalanır, anahtar üretilmez.
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

dependencies {
    implementation("com.feralin:feralin-kmp:${providers.gradleProperty("feralinVersion").get()}")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.10.2")
}
