plugins {
    application
}

val feralinVersion = providers.gradleProperty("feralinVersion").get()

dependencies {
    implementation("com.feralin:java:$feralinVersion")
}

tasks.withType<JavaCompile>().configureEach {
    options.encoding = "UTF-8"
    options.release.set(11)
}

application {
    mainClass.set("feralin.e2e.CleanInstall")
}

// Çekirdek SDK'nın çalışma zamanı bağımlılığı olmadığı kurulu çözümlemeden doğrulanır.
tasks.register("verifyNoRuntimeDependencies") {
    val files = configurations.runtimeClasspath
    doLast {
        val names = files.get().files.map { it.name }
        println("kurulu paketler: $names")
        check(names.size == 1 && names[0].startsWith("java-")) { "çalışma zamanı bağımlılığı olmamalı: $names" }
    }
}
