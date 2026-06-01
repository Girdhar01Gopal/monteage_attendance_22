plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

import java.util.Properties
        import java.io.FileInputStream

// Load local properties for versioning
val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.reader(Charsets.UTF_8).use { reader ->
        localProperties.load(reader)
    }
}

val flutterVersionCode = localProperties.getProperty("flutter.versionCode") ?: "1"
val flutterVersionName = localProperties.getProperty("flutter.versionName") ?: "1.0"

// Load keystore properties for signing
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.example.monteage_employee_app_2"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "com.example.monteage_employee_app_2"
        minSdk = 26
        targetSdk = 35
        versionCode = 6
        versionName = "1.0.6"
        multiDexEnabled = true
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        getByName("debug") {
            isDebuggable = true
            // WebSocket streaming debug ke liye logs on
        }
        getByName("release") {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false       // camera + WS code shrink hone se tod sakta hai
            isShrinkResources = false     // resources mat hatao
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
        isCoreLibraryDesugaringEnabled = true // Required for flutter_local_notifications
    }

    kotlinOptions {
        jvmTarget = "1.8"
    }

    // Camera streaming foreground service ke liye packaging options
    packagingOptions {
        resources {
            excludes += setOf(
                "META-INF/DEPENDENCIES",
                "META-INF/LICENSE",
                "META-INF/LICENSE.txt",
                "META-INF/NOTICE",
                "META-INF/NOTICE.txt",
                "META-INF/*.kotlin_module"
            )
        }
    }

    sourceSets["main"].java.srcDirs("src/main/kotlin")
}

flutter {
    source = "../.." // Make sure this path is correct if it's not default
}

dependencies {
    // Firebase BOM
    implementation(platform("com.google.firebase:firebase-bom:32.7.0"))
    implementation("com.google.firebase:firebase-analytics")

    // Required for flutter_local_notifications + attendance reminders
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")

    // MultiDex — already enabled in defaultConfig, ye uska runtime support hai
    implementation("androidx.multidex:multidex:2.0.1")

    // WebSocket + background service ke liye WorkManager (optional future use)
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // Foreground service notification channel ke liye
    implementation("androidx.core:core-ktx:1.13.1")
}