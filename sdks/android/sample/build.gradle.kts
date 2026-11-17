import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Örnek yerel collector'a bağlanır: 10.0.2.2 emülatörde ana makinenin loopback adresidir. Değer sır değildir;
// `-PfeSampleKey=...` ile değiştirilebilir. Gerçek anahtar bu dosyaya yazılmaz.
val sampleCollectUrl = providers.gradleProperty("feSampleCollectUrl").getOrElse("http://10.0.2.2:4691")
val sampleProjectKey = providers.gradleProperty("feSampleKey").getOrElse("pk_test_feralin_sample_local")
// Kurulum eşleştirme kodu (panelin doğrulama ekranı üretir, tek kullanımlık, 30 dakika). Boşsa SDK kod göndermez.
val sampleInstallCode = providers.gradleProperty("feSampleInstallCode").getOrElse("")

android {
    namespace = "com.feralin.sample"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.feralin.sample"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "0.1.0"
        buildConfigField("String", "COLLECT_URL", "\"$sampleCollectUrl\"")
        buildConfigField("String", "PROJECT_KEY", "\"$sampleProjectKey\"")
        buildConfigField("String", "INSTALL_CODE", "\"$sampleInstallCode\"")
    }

    buildFeatures {
        buildConfig = true
    }

    buildTypes {
        release {
            // R8 altında SDK'nın çalıştığını da sınar. İmzalama yapılandırılmaz; anahtar deposu üretilmez. Yalnız yerel emülatör testi
            // (`scripts/e2e-exit-info.mjs`) `-PfeSampleDebugSign=true` ile Android Gradle'ın kendi hata ayıklama anahtarını kullanır.
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (providers.gradleProperty("feSampleDebugSign").orNull == "true") signingConfig = signingConfigs.getByName("debug")
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
    implementation(project(":feralin"))
}
