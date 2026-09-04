plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.tokenburners.nova"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.tokenburners.nova"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Vosk (offline STT/wake word) requires 30; background mic + FGS types
        // effectively need 30+ anyway. Personal sideload target is Android 11+.
        minSdk = maxOf(30, flutter.minSdkVersion)

        // Personal build: arm64 only (every phone from ~2018 on). Drops the
        // 32-bit + x86 copies of libvosk/libllama. Build with --split-per-abi
        // or --target-platform android-arm64 to actually apply this.
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // Vosk uses JNA (libjnidispatch.so) + llama.cpp uses dlopen; both are far
    // more reliable when the .so files are extracted to the filesystem at
    // install time rather than mmap'd from inside the APK.
    packaging {
        jniLibs {
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
