// Temiz Android tüketicisi: sdks/kmp/scripts/e2e-emulator.mjs boş dizine kopyalar; paket yalnız yerel Maven dizininden gelir.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        maven { url = uri(providers.gradleProperty("feralinLocalRepo").get()) }
        google()
        mavenCentral()
    }
}

rootProject.name = "feralin-kmp-android-e2e"
