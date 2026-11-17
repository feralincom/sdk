val springBootVersion = providers.gradleProperty("springBootVersion").get()

tasks.withType<JavaCompile>().configureEach {
    // Spring Boot 3 ve üstü Java 17 ister; çekirdek SDK Java 11'de kalır.
    options.release.set(17)
    // Spring anotasyonlarının sınıf dosyalarındaki bilinmeyen sabitleri -Werror ile derlemeyi kırmasın.
    options.compilerArgs.add("-Xlint:-classfile")
}

configure<PublishingExtension> {
    publications.named<MavenPublication>("maven") {
        pom {
            name.set("Feralin Spring Boot Starter")
            description.set("Spring Boot auto-configuration for the Feralin Java SDK with a request-scoped Feralin bean.")
        }
    }
}

dependencies {
    val boot = platform("org.springframework.boot:spring-boot-dependencies:$springBootVersion")

    "api"(project(":java"))
    "api"("org.springframework.boot:spring-boot-autoconfigure:$springBootVersion")

    // Servlet uygulaması bunları zaten getirir; web'siz uygulamaya taşınmaz, koşullu yapılandırma kapalı kalır.
    "compileOnly"(boot)
    "compileOnly"("org.springframework:spring-web")
    "compileOnly"("jakarta.servlet:jakarta.servlet-api")

    "annotationProcessor"(boot)
    "annotationProcessor"("org.springframework.boot:spring-boot-configuration-processor")

    "testImplementation"(boot)
    "testImplementation"("org.springframework.boot:spring-boot-starter-test")
    "testImplementation"("org.springframework:spring-web")
    "testImplementation"("org.springframework:spring-aop")
    "testImplementation"("jakarta.servlet:jakarta.servlet-api")
    "testRuntimeOnly"("org.junit.platform:junit-platform-launcher")
}
