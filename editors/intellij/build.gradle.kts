import org.gradle.api.tasks.bundling.Zip
import org.jetbrains.intellij.platform.gradle.IntelliJPlatformType
import org.jetbrains.intellij.platform.gradle.TestFrameworkType

plugins {
    id("java")
    id("org.jetbrains.kotlin.jvm") version "2.4.10"
    id("org.jetbrains.intellij.platform") version "2.18.1"
}

group = "com.braycarlson"
version = "0.1.0"

repositories {
    mavenCentral()

    intellijPlatform {
        defaultRepositories()
    }
}

val ideHome = providers.gradleProperty("tigerstyleIdeHome")
val platformVersion = providers.gradleProperty("tigerstylePlatformVersion")
val floorBuild = providers.gradleProperty("tigerstyleSinceBuild")
val updateBaseUrl = providers.gradleProperty("tigerstyleUpdateBaseUrl").orElse("")

val verifyVersions = providers.gradleProperty("tigerstyleVerifyVersions")
    .map { versions -> versions.split(',').map(String::trim).filter(String::isNotEmpty) }

dependencies {
    intellijPlatform {
        if (ideHome.isPresent) {
            local(ideHome.get())
        } else {
            pycharmProfessional(platformVersion.get())
        }

        testFramework(TestFrameworkType.Platform)
    }

    testImplementation("junit:junit:4.13.2")
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild = floorBuild
            untilBuild = provider { null }
        }
    }

    pluginVerification {
        ides {
            verifyVersions.get().forEach { version ->
                create(IntelliJPlatformType.PyCharmProfessional, version)
            }
        }
    }
}

kotlin {
    jvmToolchain(21)
}

tasks.test {
    useJUnit()
}

val updatePluginsXml by tasks.registering {
    val archive = tasks.named<Zip>("buildPlugin").flatMap { it.archiveFile }
    val descriptor = layout.buildDirectory.file("distributions/updatePlugins.xml")
    val identifier = "com.braycarlson.tigerstyle"
    val released = version.toString()
    val floor = floorBuild
    val base = updateBaseUrl

    inputs.file(archive)
    outputs.file(descriptor)

    doLast {
        val name = archive.get().asFile.name
        val prefix = base.get().trimEnd('/')
        val url = if (prefix.isEmpty()) name else "$prefix/$name"

        descriptor.get().asFile.writeText(
            """
            <plugins>
                <plugin id="$identifier" url="$url" version="$released">
                    <idea-version since-build="${floor.get()}"/>
                </plugin>
            </plugins>
            """.trimIndent() + "\n",
        )
    }
}
