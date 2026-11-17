dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        mavenCentral()
    }
}

rootProject.name = "feralin-java"

// Proje adları Maven artifactId olur: com.feralin:java ve com.feralin:feralin-spring-boot-starter.
include(":java", ":feralin-spring-boot-starter")
project(":java").projectDir = file("core")
project(":feralin-spring-boot-starter").projectDir = file("spring-boot-starter")
