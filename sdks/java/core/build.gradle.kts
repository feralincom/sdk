val junitVersion = providers.gradleProperty("junitVersion").get()

tasks.withType<JavaCompile>().configureEach {
    // --release 11: kod yalnız Java 11 API'siyle derlenir; daha yeni JDK'da bile Java 17'ye özgü çağrı derlenmez.
    options.release.set(11)
}

tasks.named<Jar>("jar") {
    manifest {
        attributes(
            "Automatic-Module-Name" to "com.feralin.sdk",
            "Implementation-Title" to "feralin-java",
            "Implementation-Version" to project.version,
        )
    }
}

configure<PublishingExtension> {
    publications.named<MavenPublication>("maven") {
        pom {
            name.set("Feralin Java SDK")
            description.set("Feralin UTP v1 server SDK for Java 11+, no runtime dependencies.")
        }
    }
}

dependencies {
    // Çalışma zamanı bağımlılığı bilerek yoktur; yalnız test için JUnit.
    "testImplementation"(platform("org.junit:junit-bom:$junitVersion"))
    "testImplementation"("org.junit.jupiter:junit-jupiter")
    "testRuntimeOnly"("org.junit.platform:junit-platform-launcher")
}
