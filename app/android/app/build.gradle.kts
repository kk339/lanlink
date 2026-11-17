import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing (0.2.61). The credentials live OUTSIDE the repository, in
// `../key.properties` (next to settings.gradle.kts, ignored by
// android/.gitignore), which points at a keystore stored even further outside
// it (E:/lanlink-keys/). Neither file is ever committed.
//
// This is what makes an update installable over an older copy: Android only
// accepts a package update when the new APK is signed by the *same* key. The
// template default (debug key) is generated per machine, so a release built on
// another machine would be a different app to the system — "签名不同，装不上".
//
// The fallback is deliberate, not laziness: a fresh clone (and this project's
// public mirror) has no key.properties, and `flutter build apk --release` must
// still work there. It lands on the debug key, exactly as before.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "io.github.kk339.lanlink"
    compileSdk = flutter.compileSdkVersion
    // ndkVersion = flutter.ndkVersion
    //   ^ Deliberately disabled. This app is pure Dart (no hand-written native
    //     code), so nothing here needs the NDK to COMPILE one. Leaving the
    //     template default in place made Gradle demand the NDK package
    //     ("Package 28.2.13676358 not found"), i.e. a 1-2 GB download from a
    //     source that measures unusably slow on this machine.
    //     If a plugin ever genuinely needs the NDK, the build fails with an
    //     explicit message naming the version - re-enable this line then.

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "io.github.kk339.lanlink"
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
    }

    signingConfigs {
        // Declared only when the credentials are actually present: creating it
        // unconditionally would leave `storeFile = null` on a fresh clone and
        // fail the Gradle configuration phase itself.
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // The real release key when key.properties is present (every
            // delivered build), the debug key otherwise (a fresh clone, and the
            // public mirror, which by design carries no keystore).
            signingConfig =
                if (keystorePropertiesFile.exists()) {
                    signingConfigs.getByName("release")
                } else {
                    signingConfigs.getByName("debug")
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
