pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "9.0.1" apply false
    id("org.jetbrains.kotlin.android") version "2.3.20" apply false
}

include(":app")

// --- Compile-SDK alignment for plugin modules --------------------------------
//
// Two separate problems, one fix.
//
// 1. Google no longer publishes a plain `platforms;android-37` -- only
//    minor-versioned releases (`android-37.0`, `android-37.1`, ...). A module
//    declaring the bare `compileSdk = 37` (flutter_secure_storage 11 does) asks
//    for a platform hash that cannot exist:
//        Failed to find target with hash string 'android-37' in: <sdk>
//    AGP 9 added `compileSdkMinor` for exactly this, so 37 + 0 resolves to the
//    installed `android-37.0`.
//
// 2. Stale plugins pin a compileSdk that modern AndroidX rejects. onnxruntime
//    1.4.1 still declares `compileSdkVersion 33`, while androidx.fragment 1.7.1
//    and friends in its graph require 34+, so its `checkDebugAarMetadata` fails.
//
// Why this is in settings.gradle.kts rather than the root build script -- every
// other hook is mistimed:
//
//   * `plugins.withId` fires when AGP is applied, *before* the module's own
//     `android { ... }` block, so onnxruntime overwrites the value right back.
//   * `afterEvaluate` registered from inside that callback runs *after* AGP's own
//     afterEvaluate, and AGP 9 hard-fails with "It is too late to set compileSdk".
//   * `subprojects { afterEvaluate { ... } }` in the root script is illegal here,
//     because Flutter's plugin loader has already evaluated the plugin projects by
//     the time the root script runs.
//
// `beforeProject` is registered while settings are still being evaluated, so the
// `afterEvaluate` it installs is queued ahead of AGP's -- after the module's script
// has had its say, before AGP reads the value.
//
// Applied to every module rather than patching one plugin, because any transitive
// plugin can and will do the same thing.
gradle.beforeProject {
    afterEvaluate {
        val androidExtension =
            extensions.findByName("android") as?
                com.android.build.api.dsl.LibraryExtension
        androidExtension?.apply {
            compileSdk = providers.gradleProperty("evdekimi.compileSdk").get().toInt()
            compileSdkMinor =
                providers.gradleProperty("evdekimi.compileSdkMinor").get().toInt()
        }
    }
}
