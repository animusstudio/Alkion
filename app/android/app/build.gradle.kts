import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import groovy.json.JsonSlurper

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
}

// Private release-mode testing reuses only the disposable debug certificate.
// Never read inherited key.properties or production signing files.
val localReleaseTest =
    providers.environmentVariable("ALKION_LOCAL_RELEASE_TEST").orNull == "1" &&
        !providers.environmentVariable("ANDROID_USER_HOME").orNull.isNullOrBlank()

// Browser callback is disabled unless the optional connection build opts in.
val animusEnabled = providers.environmentVariable("ALKION_ANIMUS_NATIVE").orNull == "1"
val animusLoopbackHttp =
    providers.environmentVariable("ALKION_ANIMUS_LOOPBACK_HTTP").orNull == "1"
if (animusLoopbackHttp) {
    require(animusEnabled && gradle.startParameter.taskNames.all {
        it == "assembleDevDebug" || it == ":app:assembleDevDebug"
    }) { "Animus loopback HTTP is available only in explicit dev/debug connection builds" }
}

// A one-off synthetic device artifact, never a product flavor or release identity.
val isolatedBodyPreview =
    providers.environmentVariable("ALKION_ISOLATED_BODY_PREVIEW").orNull == "1"
val isolatedCatalogTrial =
    providers.environmentVariable("ALKION_ISOLATED_CATALOG_TRIAL").orNull == "1"
val catalogTrialAssets = file("../../build/private-catalog-trial/assets")
val catalogTrialTarget = file("../../lib/catalog_trial.dart").canonicalFile
val configuredTarget = providers.gradleProperty("target").orNull?.let {
    val candidate = File(it)
    (if (candidate.isAbsolute) candidate else File(file("../.."), it)).canonicalFile
}
require(!animusEnabled || (!isolatedBodyPreview && !isolatedCatalogTrial &&
    providers.environmentVariable("ALKION_BODY_PREVIEW_OFFLINE").orNull != "1")) {
    "An offline preview or catalog trial cannot enable an Animus connection"
}
require(!(isolatedBodyPreview && isolatedCatalogTrial)) {
    "Select only one isolated development target"
}
if (isolatedCatalogTrial || configuredTarget == catalogTrialTarget) {
    val requestedTasks = gradle.startParameter.taskNames
    val onlyDebugApk = requestedTasks.size == 1 && requestedTasks.single() in
        setOf("assembleDevDebug", ":app:assembleDevDebug")
    val signerHome = providers.environmentVariable("ANDROID_USER_HOME").orNull
    require(
        isolatedCatalogTrial && onlyDebugApk && configuredTarget == catalogTrialTarget &&
            !localReleaseTest && !animusEnabled &&
            providers.environmentVariable("ALKION_BODY_PREVIEW_OFFLINE").orNull != "1" &&
            providers.environmentVariable("ALKION_PRIVATE_BODY_ASSETS").orNull != "1" &&
            !signerHome.isNullOrBlank() && File(signerHome, "debug.keystore").isFile
    ) {
        "Catalog trial requires only assembleDevDebug, its isolated target, offline assets " +
            "and an existing explicit disposable debug signer"
    }
    val relativeFiles = setOf(
        "flutter_assets/assets/catalog_trial/catalog.dev.json",
        "flutter_assets/assets/catalog_trial/manifest.dev.json",
    )
    require(catalogTrialAssets.isDirectory &&
        catalogTrialAssets.walkTopDown().none { Files.isSymbolicLink(it.toPath()) } &&
        catalogTrialAssets.walkTopDown().filter { it.isFile }
            .map { it.relativeTo(catalogTrialAssets).invariantSeparatorsPath }.toSet() == relativeFiles
    ) { "Stage and verify the exact private catalog trial assets first" }
    val manifest = JsonSlurper().parse(
        File(catalogTrialAssets, "flutter_assets/assets/catalog_trial/manifest.dev.json")
    ) as? Map<*, *>
    val payload = File(catalogTrialAssets, "flutter_assets/assets/catalog_trial/catalog.dev.json")
    val payloadDigest = MessageDigest.getInstance("SHA-256").digest(payload.readBytes())
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    require(manifest != null && manifest["format"] == "alkion-catalog-trial-manifest" &&
        manifest["schema_version"] == 1 && manifest["private_trial_only"] == true &&
        manifest["redistribution_cleared"] == false && manifest["media_included"] == false &&
        manifest["projection_sha256"] == payloadDigest
    ) { "Private catalog trial admission manifest or projection digest is invalid" }
}
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
        manifestPlaceholders["oidcRedirectScheme"] = "dev.animusstudio.alkion"
        manifestPlaceholders["alkionAnimusEnabled"] = animusEnabled.toString()
        manifestPlaceholders["alkionNetworkSecurityConfig"] = if (animusLoopbackHttp)
            "@xml/animus_loopback_network_security_config" else "@xml/network_security_config"
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
    if (isolatedCatalogTrial) {
        sourceSets.getByName("debug").manifest.srcFile("src/catalogTrial/AndroidManifest.xml")
        sourceSets.getByName("main").assets.srcDir(catalogTrialAssets)
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
            manifestPlaceholders["oidcRedirectScheme"] = "dev.animusstudio.alkion.dev"
            if (isolatedCatalogTrial) {
                applicationId = "dev.animusstudio.alkion.catalogtrial"
                manifestPlaceholders["alkionLabel"] = "Alkion Exercise Trial"
            } else if (isolatedBodyPreview) {
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
    if (animusEnabled) {
        sourceSets.getByName("dev").manifest.srcFile("src/animusConnection/AndroidManifest.xml")
        sourceSets.getByName("supported").manifest.srcFile("src/animusConnection/AndroidManifest.xml")
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
