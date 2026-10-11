import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is driven by android/key.properties (gitignored). Absent on
// machines without the key (contributors, PR CI) — falls back to debug signing.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Capture-bridge distribution builds (`make -C app build-capture-apk-release`)
// set the Gradle property captureDistribution=true (through the environment
// variable ORG_GRADLE_PROJECT_captureDistribution). For them the debug-signing
// fallback below is disabled: without the release signing configuration the
// build fails here, during configuration, before any task can produce an APK.
// Only the presence of the signing file is tested; no signing value is read
// for this check or printed. Without the property every build behaves exactly
// as before.
val captureDistribution = when (providers.gradleProperty("captureDistribution").orNull) {
    null, "false" -> false
    "true" -> true
    else -> throw GradleException("captureDistribution must be true or false")
}
if (captureDistribution && !keystorePropertiesFile.exists()) {
    throw GradleException(
        "Capture distribution requires the release signing configuration " +
            "(android/key.properties, see android/RELEASE.md); " +
            "debug signing is not allowed for a capture bridge."
    )
}

android {
    namespace = "io.github.psychonaut0.reps"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.psychonaut0.reps"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with our release key when key.properties is present; otherwise
            // fall back to debug signing so `flutter build apk --release` still works.
            // A capture distribution build never takes the fallback (see above).
            signingConfig = if (keystorePropertiesFile.exists())
                signingConfigs.getByName("release")
            else if (captureDistribution)
                throw GradleException("Capture distribution must use release signing.")
            else
                signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
