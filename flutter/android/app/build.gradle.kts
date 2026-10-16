plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Override with -PfctvAbiFilters=arm64-v8a,armeabi-v7a (TV and phones).
// Default drops x86/x86_64 which are emulator-only and inflate the fat APK.
val fctvAbiFilters: List<String> =
    (project.findProperty("fctvAbiFilters") as String?)
        ?.split(",")
        ?.map { it.trim() }
        ?.filter { it.isNotEmpty() }
        ?: listOf("arm64-v8a", "armeabi-v7a")

val allJniAbis = listOf("armeabi", "armeabi-v7a", "arm64-v8a", "x86", "x86_64", "mips", "mips64")

android {
    namespace = "com.fctv33.fctv33"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.fctv33.fctv33"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters.clear()
            abiFilters += fctvAbiFilters
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }

    // media_kit ships libmpv for every ABI inside its AAR. ndk.abiFilters alone
    // does not always strip those; packaging excludes guarantee they stay out.
    packaging {
        jniLibs {
            for (abi in allJniAbis) {
                if (abi !in fctvAbiFilters) {
                    excludes += "**/lib/$abi/**"
                    excludes += "**/$abi/*.so"
                }
            }
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
