allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Note: the compile-SDK alignment for plugin modules lives in settings.gradle.kts.
// It has to be registered before any project script runs, so it cannot live here.

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
