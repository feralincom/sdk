plugins {
    application
}

val feralinVersion = providers.gradleProperty("feralinVersion").get()
val springBootVersion = providers.gradleProperty("springBootVersion").get()

dependencies {
    implementation(platform("org.springframework.boot:spring-boot-dependencies:$springBootVersion"))
    implementation("org.springframework.boot:spring-boot-starter-web")
    implementation("com.feralin:feralin-spring-boot-starter:$feralinVersion")
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
    options.release.set(17)
}

application {
    mainClass.set("feralin.e2e.SpringCleanInstall")
}
