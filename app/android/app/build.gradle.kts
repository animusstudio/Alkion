plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Debug variants only. Never read inherited key.properties/signing files.
// Owner signing and release tasks require a separately selected route.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.name.contains("Release", ignoreCase = true) }) {
        throw GradleException("Alkion release identity/signing is not selected.")
    }
}

android {
    namespace = "dev.animusstudio.alkion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "dev.animusstudio.alkion"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }
    buildFeatures {
        buildConfig = true
    }
    flavorDimensions += "installation"
    productFlavors {
        create("dev") {
            dimension = "installation"
            applicationIdSuffix = ".dev"
            manifestPlaceholders["alkionLabel"] = "Alkion Dev"
        }
        create("supported") {
            dimension = "installation"
            manifestPlaceholders["alkionLabel"] = "Alkion"
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
flutter { source = "../.." }
