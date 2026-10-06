import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Hanya terapkan Google Services jika google-services.json valid (berisi mobilesdk_app_id).
// File JSON service account Firebase (Admin SDK) TIDAK bisa dipakai di sini — unduh dari
// Firebase Console: Project settings > Your apps > Android > Download google-services.json
val googleServicesJson = file("google-services.json")
val hasFirebaseAndroidConfig = try {
    googleServicesJson.exists() &&
        googleServicesJson.readText().contains("\"mobilesdk_app_id\": \"1:")
} catch (_: Exception) {
    false
}
// Build "Atenim Dev" (ATENIM_DEV=1): paket com.atenim.dev, label "Atenim Dev", terpasang berdampingan
// dengan app asli. google-services.json hanya berisi klien com.atenim, jadi plugin dilewati
// (push mati di build ini; app sudah menangani Firebase yang belum siap).
val isDevBuild = System.getenv("ATENIM_DEV") == "1"
if (hasFirebaseAndroidConfig && !isDevBuild) {
    apply(plugin = "com.google.gms.google-services")
}

// Load keystore properties
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Load .env values for manifest placeholders (e.g., Google Maps API key)
val envProperties = Properties()
val envFile = rootProject.file("../.env")
if (envFile.exists()) {
    envFile.forEachLine { rawLine ->
        val line = rawLine.trim()
        if (line.isEmpty() || line.startsWith("#")) {
            return@forEachLine
        }
        val separatorIndex = line.indexOf("=")
        if (separatorIndex <= 0) {
            return@forEachLine
        }
        val key = line.substring(0, separatorIndex).trim()
        var value = line.substring(separatorIndex + 1).trim()
        if ((value.startsWith("\"") && value.endsWith("\"")) ||
            (value.startsWith("'") && value.endsWith("'"))) {
            value = value.substring(1, value.length - 1)
        }
        envProperties.setProperty(key, value)
    }
}

android {
    namespace = "com.atenim"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.atenim"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["MAPS_API_KEY"] = envProperties.getProperty("GOOGLE_MAPS_API_KEY") ?: ""
        manifestPlaceholders["appLabel"] = if (isDevBuild) "Atenim Dev" else "Atenim"
        // HTTP polos hanya untuk build uji ke server lokal (ATENIM_CLEARTEXT=1); build biasa tetap HTTPS saja.
        manifestPlaceholders["cleartext"] = if (System.getenv("ATENIM_CLEARTEXT") == "1") "true" else "false"
        if (isDevBuild) {
            applicationIdSuffix = ".dev"
            versionNameSuffix = "-dev"
        }
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            // Use release signing config if keystore exists, otherwise fallback to debug
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Disable stripping debug symbols to avoid build errors
            // This warning is non-critical - the bundle will still work fine
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
    
    // Disable native library stripping to avoid build warnings
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.0.4")
}

flutter {
    source = "../.."
}
