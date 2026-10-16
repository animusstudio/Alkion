plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Development identity only. Never read inherited key.properties/signing files.
// Release tasks remain unavailable until a separately reviewed release route.
gradle.taskGraph.whenReady {
    if (allTasks.any { it.name.contains("Release", ignoreCase = true) }) {
        throw GradleException("Alkion release identity/signing is not selected.")
    }
}

android {
    namespace = "dev.animusstudio.alkion.dev"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion
    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    defaultConfig {
        applicationId = "dev.animusstudio.alkion.dev"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
