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
            // Off for `bundleRelease`. An app bundle does its own per-ABI split
            // at the store, so having Gradle also split produces four shrunk
            // resource sets where the bundle task expects one, and it fails
            // with "Multiple shrunk-resources files found".
            //
            // The two are alternatives, not layers: splits are how you hand
            // someone an APK for a known device, bundles are how you ship. This
            // keeps the APK path splitting and lets the AAB path do its own —
            // the alternative, deleting the block, would make every debug APK a
            // fat one carrying three ABIs of ONNX Runtime.
            isEnable = !gradle.startParameter.taskNames.any {
                it.contains("Bundle", ignoreCase = true)
            }
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
            // Signed with the debug keys so `flutter run --release` and CI's
            // unsigned artefact both work. A real release needs a keystore and
            // a signing config read from CI secrets.
            signingConfig = signingConfigs.getByName("debug")

            // R8 needs rules the plugins do not ship. See proguard-rules.pro:
            // ML Kit references four script recognizers this app does not
            // depend on, and ONNX Runtime is reached over JNI where R8 cannot
            // see the references. Without this the release build fails outright
            // and only the release build — `flutter run` never invokes R8, so
            // it hides until CI or a store upload.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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
