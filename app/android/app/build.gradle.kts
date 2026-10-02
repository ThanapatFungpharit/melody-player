import java.io.File

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.flet.musicplayer"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Melody's Flet releases used this identity. Keeping it makes this an
        // in-place upgrade that retains the user's library and settings.
        applicationId = "com.flet.musicplayer"
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val releaseKeyStore = System.getenv("MELODY_ANDROID_KEY_STORE").orEmpty()
    signingConfigs {
        if (releaseKeyStore.isNotBlank()) {
            create("release") {
                storeFile = File(releaseKeyStore)
                storePassword = System.getenv("MELODY_ANDROID_KEY_STORE_PASSWORD")
                keyPassword = System.getenv("MELODY_ANDROID_KEY_PASSWORD")
                keyAlias = System.getenv("MELODY_ANDROID_KEY_ALIAS")
            }
        }
    }

    buildTypes {
        release {
            // tools/build_app.py requires the release key for production
            // builds; local release runs fall back to debug signing.
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }

    packaging {
        jniLibs {
            // FFmpeg ships as libffmpeg.so/libffprobe.so executables. Legacy
            // packaging makes the installer extract them to the read-only,
            // executable nativeLibraryDir (Android 10+ forbids executing
            // programs from writable app storage).
            useLegacyPackaging = true
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
