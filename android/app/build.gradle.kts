plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "id.evdekimi.evdekimi_ai"

    // Not flutter.compileSdkVersion: that yields a bare major (37), and Google now
    // publishes only minor-versioned platforms, so it resolves to a non-existent
    // `android-37`. Values come from gradle.properties, shared with every plugin
    // module via the subprojects block in ../build.gradle.kts.
    compileSdk = providers.gradleProperty("evdekimi.compileSdk").get().toInt()
    compileSdkMinor = providers.gradleProperty("evdekimi.compileSdkMinor").get().toInt()

    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "id.evdekimi.evdekimi_ai"
        minSdk = providers.gradleProperty("evdekimi.minSdk").get().toInt()
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ONNX Runtime and ML Kit ship prebuilt .so files per ABI. Splitting by ABI
    // keeps the delivered APK close to a single architecture's size instead of
    // bundling every one into a fat binary.
    splits {
        abi {
            isEnable = true
            reset()
            include("armeabi-v7a", "arm64-v8a", "x86_64")
            isUniversalApk = true
        }
    }

    packaging {
        // Several native dependencies ship duplicate licence metadata; without
        // this the merge step fails on a duplicate-file conflict.
        resources.excludes += setOf(
            "META-INF/LICENSE*",
            "META-INF/NOTICE*",
            "META-INF/DEPENDENCIES",
        )
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
