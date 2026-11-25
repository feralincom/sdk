import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

val feralinVersion = providers.gradleProperty("feralinVersion").get()

group = "com.feralin"
version = feralinVersion

android {
    namespace = "com.feralin.android"
    compileSdk = 36

    defaultConfig {
        // minSdk 24: ConnectivityManager.registerDefaultNetworkCallback API 24 ister ve Flutter 3.38'in
        // varsayılan minSdk değeri de 24'tür; Android ve Flutter SDK'ları aynı tabanı paylaşır.
        minSdk = 24
        buildConfigField("String", "FERALIN_VERSION", "\"$feralinVersion\"")
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    testOptions {
        unitTests.all {
            it.testLogging {
                events("failed", "skipped")
                exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
            }
        }
    }

    publishing {
        // Maven Central kaynak ve javadoc jar'ı ister.
        singleVariant("release") {
            withSourcesJar()
            withJavadocJar()
        }
    }
}

// Yalnız yerel dizine yayın: React Native paketi çekirdeği ve Maven Central paketi (scripts/sdk-publish/maven-publish.mjs) buradan
// alınır. Uzak depo ve kimlik bilgisi tanımlı değildir; bu görev hiçbir registry'ye yükleme yapamaz. POM alanları Maven Central
// zorunluluklarıdır (ad, açıklama, adres, lisans, geliştirici, SCM).
publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "com.feralin"
            artifactId = "android"
            version = feralinVersion
            afterEvaluate { from(components["release"]) }
            pom {
                name.set("Feralin Android SDK")
                description.set("Feralin Android SDK: izin öncelikli olaylar, kalıcı kuyruk, Play Install Referrer ve App Link atfı.")
                url.set("https://feralin.com")
                licenses {
                    license {
                        name.set("MIT")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }
                developers {
                    developer {
                        id.set("feralin")
                        name.set("Feralin")
                        email.set("noreply@feralin.com")
                        organization.set("Feralin")
                        organizationUrl.set("https://feralin.com")
                    }
                }
                scm {
                    url.set("https://github.com/feralincom/sdk")
                    connection.set("scm:git:https://github.com/feralincom/sdk.git")
                    developerConnection.set("scm:git:https://github.com/feralincom/sdk.git")
                }
            }
        }
    }
    repositories {
        maven {
            name = "localVendor"
            url = uri(providers.gradleProperty("feralinVendorRepo").getOrElse(layout.buildDirectory.dir("local-repo").get().asFile.path))
        }
    }
}

kotlin {
    explicitApi()
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_11)
    }
}

dependencies {
    // Gerçek (implementation) bağımlılık, compileOnly değil: Play Install Referrer bu SDK'nın ana Android
    // attribution yoludur. compileOnly seçilseydi uygulama eklemeyi unuttuğunda attribution sessizce "none"
    // kalırdı. Kütüphane 8 KB'lık tek AAR'dır, geçişli bağımlılığı yoktur ve yalnız
    // BIND_GET_INSTALL_REFERRER_SERVICE iznini ekler. Play dışı dağıtımda hariç tutulabilir; o durumda
    // NoClassDefFoundError yakalanır ve kaynak "none" olur.
    implementation("com.android.installreferrer:installreferrer:2.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.17")
    // android.jar içindeki org.json saplamaları saf JVM testlerinde çalışmaz; yalnız test için gerçek uygulama.
    testImplementation("org.json:json:20260814")
}
