import java.io.File

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Private release-mode testing reuses only the disposable debug certificate.
// Never read inherited key.properties or production signing files.
val localReleaseTest =
    providers.environmentVariable("ALKION_LOCAL_RELEASE_TEST").orNull == "1" &&
        !providers.environmentVariable("ANDROID_USER_HOME").orNull.isNullOrBlank()

// A one-off synthetic device artifact, never a product flavor or release identity.
val isolatedBodyPreview =
    providers.environmentVariable("ALKION_ISOLATED_BODY_PREVIEW").orNull == "1"
if (isolatedBodyPreview) {
    val requestedTasks = gradle.startParameter.taskNames
    val onlyDebugApk = requestedTasks.size == 1 && requestedTasks.single() in
        setOf("assembleDevDebug", ":app:assembleDevDebug")
    val target = providers.gradleProperty("target").orNull
    val previewTarget = file("../../lib/character_body_preview.dart").canonicalFile
    val resolvedTarget = target?.let {
        val candidate = File(it)
        (if (candidate.isAbsolute) candidate else File(file("../.."), it)).canonicalFile
    }
    val signerHome = providers.environmentVariable("ANDROID_USER_HOME").orNull
    require(
        onlyDebugApk && resolvedTarget == previewTarget && !localReleaseTest &&
            providers.environmentVariable("ALKION_BODY_PREVIEW_OFFLINE").orNull == "1" &&
            !signerHome.isNullOrBlank() && File(signerHome, "debug.keystore").isFile
    ) {
        "Isolated body preview requires only assembleDevDebug, the synthetic preview target, " +
            "offline preview manifest and an existing explicit disposable debug signer"
    }
}

gradle.taskGraph.whenReady {
    if (allTasks.any { it.name.contains("Release", ignoreCase = true) }) {
        val requestedTasks = gradle.startParameter.taskNames
        val onlyDevApk = requestedTasks.size == 1 && requestedTasks.single() in
            setOf("assembleDevRelease", ":app:assembleDevRelease")
        val forbiddenAppTasks = allTasks.filter {
            // AGP includes this empty lifecycle helper in the dev APK graph.
            val emptyVariantPreparation =
                it.name == "preSupportedReleaseBuild" && it.actions.isEmpty()
            it.project == project &&
                it.name.contains("SupportedRelease", ignoreCase = true) &&
                !emptyVariantPreparation
        }
        if (!localReleaseTest || !onlyDevApk || forbiddenAppTasks.isNotEmpty()) {
            throw GradleException(
                "Release tasks require the opt-in local dev APK test route; " +
                    "production signing and bundles remain unavailable. " +
                    "Guard: requestedTasks=$requestedTasks, localReleaseTest=$localReleaseTest, " +
                    "onlyDevApk=$onlyDevApk, forbiddenAppTasks=" +
                    forbiddenAppTasks.map { "${it.path} (${it.javaClass.simpleName})" } + "."
            )
        }
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
        if (localReleaseTest) {
            ndk.abiFilters.clear()
            ndk.abiFilters.add("arm64-v8a")
        }
    }
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }
    if (providers.environmentVariable("ALKION_BODY_PREVIEW_OFFLINE").orNull == "1") {
        sourceSets.getByName("debug").manifest.srcFile("src/bodyPreview/AndroidManifest.xml")
    }
    // Generated private inputs are included only by explicit local build opt-in.
    // Default/public builds contain the generic runtime and truthful absent-art UI.
    if (providers.environmentVariable("ALKION_PRIVATE_BODY_ASSETS").orNull == "1") {
        val bodyAssets = file("../../build/private-character-body/assets")
        require(File(bodyAssets, "body_models/staged.json").isFile) {
            "Stage explicit private body assets before enabling ALKION_PRIVATE_BODY_ASSETS"
        }
        sourceSets.getByName("main").assets.srcDir(bodyAssets)
    }
    buildFeatures {
        buildConfig = true
    }
    buildTypes {
        getByName("release") {
            if (localReleaseTest) {
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
    flavorDimensions += "installation"
    productFlavors {
        create("dev") {
            dimension = "installation"
            applicationIdSuffix = ".dev"
            if (isolatedBodyPreview) {
                applicationId = "dev.animusstudio.alkion.bodypreview"
                manifestPlaceholders["alkionLabel"] = "Body renderer preview"
            } else {
                manifestPlaceholders["alkionLabel"] = "Alkion Dev"
            }
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
