val feralinRepo = providers.gradleProperty("feralinRepo").get()

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        // com.feralin yalnız test edilen yerel depodan gelir; aynı adlı başka bir paket Central'dan karışamaz.
        exclusiveContent {
            forRepository { maven { url = uri(feralinRepo) } }
            filter { includeGroup("com.feralin") }
        }
        mavenCentral()
    }
}

rootProject.name = "feralin-java-clean-install"
