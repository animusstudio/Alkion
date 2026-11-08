import java.io.File
import java.net.URI
import java.nio.file.Files
import java.security.MessageDigest
import java.util.Base64
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

// Both compiler setup and native build must explicitly select this debug policy.
// Decode only setup locators; never print Dart-define values in errors.
val animusPrivateHttp = providers.environmentVariable("ALKION_ANIMUS_PRIVATE_HTTP").orNull == "1"
val connectionDefines = try {
    val pairs = providers.gradleProperty("dart-defines").orNull.orEmpty()
        .split(',').filter { it.isNotEmpty() }.map {
            String(Base64.getDecoder().decode(it), Charsets.UTF_8).split('=', limit = 2)
        }.filter { it.size == 2 && it[0].startsWith("ALKION_ANIMUS_") }
    require(pairs.map { it[0] }.toSet().size == pairs.size)
    pairs.associate { it[0] to it[1] }
} catch (_: Exception) {
    throw GradleException("Invalid connection build setup")
}
val privateHttpDart = connectionDefines["ALKION_ANIMUS_ALLOW_PRIVATE_HTTP"] == "true"
val privateHttpResources = file("../../build/private-animus-http/res")
if (animusPrivateHttp || privateHttpDart) {
    val tasks = gradle.startParameter.taskNames
    require(animusPrivateHttp && privateHttpDart && animusEnabled && !animusLoopbackHttp &&
        !localReleaseTest && tasks.size == 1 && tasks.single() in
        setOf("assembleDevDebug", ":app:assembleDevDebug")) {
        "Private HTTP requires matching setup and only the explicit Dev/debug APK task"
    }
    require(connectionDefines["ALKION_ANIMUS_ENABLED"] == "true" &&
        connectionDefines["ALKION_ANIMUS_ALLOW_LOOPBACK_HTTP"] != "true" &&
        connectionDefines["ALKION_ANIMUS_ENROLLMENT_FLOW"].isNullOrEmpty() &&
        connectionDefines["ALKION_ANIMUS_REDIRECT_URI"] == "dev.animusstudio.alkion.dev:/oauth2redirect") {
        "Private HTTP connection setup is incomplete or incompatible"
    }
    fun privateHost(key: String, issuer: Boolean): String {
        val text = connectionDefines[key] ?: throw GradleException("Missing connection origin")
        val uri = try { URI(text) } catch (_: Exception) { throw GradleException("Invalid connection origin") }
        val host = uri.host.orEmpty()
        val hostPattern = Regex("^[a-z0-9]+(?:[.-][a-z0-9-]+)*$")
        require(uri.scheme == "http" && hostPattern.matches(host) && uri.rawUserInfo == null &&
            uri.rawQuery == null && uri.rawFragment == null && uri.port in -1..65535 && uri.port != 0 &&
            uri.rawAuthority == host + (if (uri.port == -1) "" else ":${uri.port}") &&
            (if (issuer) Regex("^/application/o/[A-Za-z0-9_-]+/$").matches(uri.rawPath.orEmpty())
             else uri.rawPath.isNullOrEmpty() || uri.rawPath == "/")) {
            "Invalid private HTTP connection origin"
        }
        return host
    }
    val hosts = setOf(privateHost("ALKION_ANIMUS_API_ORIGIN", false),
        privateHost("ALKION_ANIMUS_ISSUER", true))
    val xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n" +
        "<network-security-config><base-config cleartextTrafficPermitted=\"false\"/>" +
        "<domain-config cleartextTrafficPermitted=\"true\">" +
        hosts.joinToString("") { "<domain includeSubdomains=\"false\">$it</domain>" } +
        "</domain-config></network-security-config>\n"
    val output = File(privateHttpResources, "xml/animus_private_http_network_security_config.xml")
    output.parentFile.mkdirs()
    output.writeText(xml)
}

// A one-off synthetic device artifact, never a product flavor or release identity.
val isolatedBodyPreview =
    providers.environmentVariable("ALKION_ISOLATED_BODY_PREVIEW").orNull == "1"
val privateCatalogDev =
    providers.environmentVariable("ALKION_PRIVATE_CATALOG_DEV").orNull == "1"
val catalogDevDefined = providers.gradleProperty("dart-defines").orNull
    ?.split(",")?.any {
        runCatching { String(Base64.getDecoder().decode(it), Charsets.UTF_8) }
            .getOrNull() == "ALKION_CATALOG_DEV=true"
    } == true
require(catalogDevDefined == privateCatalogDev) {
    "Private Dev catalog requires matching native and Dart opt-ins"
}
val privateCatalogAssets = file("../../build/private-catalog-dev/assets")
val catalogDevTarget = file("../../lib/main.dart").canonicalFile
val configuredTarget = providers.gradleProperty("target").orNull?.let {
    val candidate = File(it)
    (if (candidate.isAbsolute) candidate else File(file("../.."), it)).canonicalFile
}
require(!animusEnabled || (!isolatedBodyPreview &&
    providers.environmentVariable("ALKION_BODY_PREVIEW_OFFLINE").orNull != "1")) {
    "An offline preview cannot enable an Animus connection"
}
require(!privateCatalogDev || !isolatedBodyPreview) {
    "Normal Dev catalog cannot use an isolated preview"
}
if (privateCatalogDev) {
    val requestedTasks = gradle.startParameter.taskNames
    val onlyDebugApk = requestedTasks.size == 1 && requestedTasks.single() in
        setOf("assembleDevDebug", ":app:assembleDevDebug")
    val onlyLocalReleaseApk = requestedTasks.size == 1 && requestedTasks.single() in
        setOf("assembleDevRelease", ":app:assembleDevRelease") && localReleaseTest
    val signerHome = providers.environmentVariable("ANDROID_USER_HOME").orNull
    require(
        (onlyDebugApk || onlyLocalReleaseApk) && configuredTarget == catalogDevTarget &&
            (!animusEnabled || onlyDebugApk) &&
            providers.environmentVariable("ALKION_BODY_PREVIEW_OFFLINE").orNull != "1" &&
            !signerHome.isNullOrBlank() && File(signerHome, "debug.keystore").isFile
    ) {
        "Private catalog requires its exact Dev target/task, compatible assets " +
            "and an existing explicit disposable debug signer"
    }
    require(privateCatalogAssets.isDirectory &&
        generateSequence(privateCatalogAssets) { it.parentFile }
            .none { Files.isSymbolicLink(it.toPath()) } &&
        privateCatalogAssets.walkTopDown().none { Files.isSymbolicLink(it.toPath()) }
    ) { "Stage the private catalog assets without redirected paths first" }
    val manifest = JsonSlurper().parse(
        File(privateCatalogAssets, "flutter_assets/assets/catalog_trial/manifest.dev.json")
    ) as? Map<*, *>
    val browseMetadata = manifest?.get("browse") as? Map<*, *>
    // Schema 4 (Dev only) adds the versioned muscle bundle and its trusted scope registry.
    val muscleMetadata = manifest?.get("muscle_bundle") as? Map<*, *>
    val scopeMetadata = manifest?.get("scope_registry") as? Map<*, *>
    val muscleSchema = manifest?.get("schema_version") == 4 &&
        muscleMetadata != null && scopeMetadata != null
    val stagedDigest = { name: String ->
        MessageDigest.getInstance("SHA-256").digest(
            File(privateCatalogAssets, "flutter_assets/assets/catalog_trial/$name").readBytes()
        ).joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
    val relativeFiles = setOf(
        "flutter_assets/assets/catalog_trial/catalog.dev.json",
        "flutter_assets/assets/catalog_trial/manifest.dev.json",
    ) + (if (manifest?.get("schema_version") in setOf(2, 3, 4) && browseMetadata != null)
        setOf("flutter_assets/assets/catalog_trial/browse.dev.json") else emptySet()) +
        if (muscleSchema) setOf(
            "flutter_assets/assets/catalog_trial/muscles.dev.json",
            "flutter_assets/assets/catalog_trial/muscle-scopes.dev.json",
        ) else emptySet()
    require(privateCatalogAssets.walkTopDown().filter { it.isFile }
            .map { it.relativeTo(privateCatalogAssets).invariantSeparatorsPath }.toSet() == relativeFiles
    ) { "Stage and verify the exact private catalog assets first" }
    val payload = File(privateCatalogAssets, "flutter_assets/assets/catalog_trial/catalog.dev.json")
    val payloadDigest = MessageDigest.getInstance("SHA-256").digest(payload.readBytes())
        .joinToString("") { "%02x".format(it.toInt() and 0xff) }
    // The staged input manifest's private_trial_only key must never ship.
    val admittedScope = manifest != null &&
        manifest["format"] == "alkion-catalog-development-manifest" &&
        (manifest["schema_version"] == 3 || muscleSchema) &&
        manifest["private_development_only"] == true &&
        !manifest.containsKey("private_trial_only")
    require(manifest != null && admittedScope &&
        manifest["redistribution_cleared"] == false && manifest["media_included"] == false &&
        manifest["projection_sha256"] == payloadDigest
    ) { "Private catalog admission manifest or projection digest is invalid" }
    require((manifest["schema_version"] in setOf(1, 3, 4) && browseMetadata == null) ||
        (manifest["schema_version"] in setOf(2, 3, 4) && browseMetadata != null &&
            browseMetadata["projection_sha256"] == stagedDigest("browse.dev.json"))
    ) { "Private catalog browse admission digest is invalid" }
    require(!muscleSchema || (
        muscleMetadata?.get("source_sha256") == stagedDigest("muscles.dev.json") &&
            scopeMetadata?.get("source_sha256") == stagedDigest("muscle-scopes.dev.json"))
    ) { "Private catalog muscle admission digest is invalid" }
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
        buildConfigField("boolean", "PRIVATE_CATALOG_DEV", privateCatalogDev.toString())
        // Aggregate body timing log (stage times, frame and message counts
        // only): honored only for the private Dev build, off by default.
        buildConfigField("boolean", "BODY_TIMING", (privateCatalogDev &&
            providers.environmentVariable("ALKION_BODY_TIMING").orNull == "1").toString())
        manifestPlaceholders["alkionNetworkSecurityConfig"] = when {
            animusPrivateHttp -> "@xml/animus_private_http_network_security_config"
            animusLoopbackHttp -> "@xml/animus_loopback_network_security_config"
            else -> "@xml/network_security_config"
        }
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
    if (privateCatalogDev) {
        if (!animusEnabled) {
            sourceSets.getByName("debug").manifest.srcFile("src/privateCatalog/AndroidManifest.xml")
        }
        sourceSets.getByName("main").assets.srcDir(privateCatalogAssets)
        // Exact JNI hash admission compares the generated and packaged bytes.
        if (!localReleaseTest) {
            packaging.jniLibs.keepDebugSymbols.addAll(setOf(
                "**/libsqlite3.so",
                "**/libsqlite3_connection_pool.so",
            ))
        }
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
    if (animusPrivateHttp) {
        sourceSets.getByName("dev").res.srcDir(privateHttpResources)
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
