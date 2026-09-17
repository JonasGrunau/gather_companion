plugins {
    id("com.android.application")
    id("com.google.gms.google-services")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.jonasgrunau.gather_companion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // `flutter_local_notifications` schedules with `java.time`, which does not
        // exist below API 26. Desugaring back-fills it rather than raising the
        // floor to 26 and dropping every phone between.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.jonasgrunau.gather_companion"
        // Stated rather than inherited from `flutter.minSdkVersion`, because two
        // plugins have a floor of their own and a Flutter upgrade that lowered
        // the default would fail the build somewhere less obvious than here:
        // `flutter_local_notifications` needs 24 and `flutter_webrtc` needs 21.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // The debug key, deliberately, for now. This half of the app is not on
            // Play and is handed round as an APK, and a debug-signed release build
            // installs and runs exactly like any other — what it cannot do is
            // upgrade over a differently-signed copy, or go to Play. Both of those
            // are decisions to make when there is a store listing to make them
            // for; inventing a keystore before then just creates a secret nobody
            // has anywhere to keep yet.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
