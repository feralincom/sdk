val feralinVersion = providers.gradleProperty("feralinVersion").get()

subprojects {
    apply(plugin = "java-library")
    apply(plugin = "maven-publish")

    group = "com.feralin"
    version = feralinVersion

    configure<JavaPluginExtension> {
        withSourcesJar()
        withJavadocJar()
    }

    tasks.withType<JavaCompile>().configureEach {
        options.encoding = "UTF-8"
        options.compilerArgs.addAll(listOf("-Xlint:all,-processing", "-Werror"))
    }

    tasks.withType<Javadoc>().configureEach {
        val standard = options as StandardJavadocDocletOptions
        standard.encoding = "UTF-8"
        standard.docEncoding = "UTF-8"
        standard.charSet = "UTF-8"
        standard.addStringOption("Xdoclint:all,-missing", "-quiet")
    }

    tasks.withType<Test>().configureEach {
        useJUnitPlatform()
        systemProperty("feralin.expectedVersion", feralinVersion)
        systemProperty("file.encoding", "UTF-8")
        testLogging {
            events("failed", "skipped")
            exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
        }
    }

    // Yalnız yerel dizine yayın: temiz kurulum testi ve dry-run buradan okur. Uzak depo ve kimlik bilgisi tanımlı
    // değildir; bu görev hiçbir registry'ye yükleme yapamaz (Maven Central BLOCKED_EXTERNAL).
    configure<PublishingExtension> {
        publications {
            register<MavenPublication>("maven") {
                from(components["java"])
                pom {
                    name.set("Feralin Java SDK: ${project.name}")
                    description.set("Feralin Java sunucu SDK'sı (${project.name}): UTP v1 olayları, izin aktarımı, idempotent batch.")
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
}
