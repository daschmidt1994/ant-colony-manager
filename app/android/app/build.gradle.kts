import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing: app/android/key.properties (created by CI from secrets or by
// you locally). Without it, release builds are signed with the debug key.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) FileInputStream(f).use { load(it) }
}

// Test app (-PdevBuild=true or ORG_GRADLE_PROJECT_devBuild=true): own app ID
// and name, so it installs next to the real app and talks to the test server.
val devBuild = (project.findProperty("devBuild") as String?) == "true"

android {
    namespace = "at.antcolony.manager"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications (scheduled reminders) needs java.time on old Android versions
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = if (devBuild) "at.antcolony.manager.dev" else "at.antcolony.manager"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Domain for verified App Links (camera QR opens the app directly).
        // Set with -PappLinkHost=ants.example.com or ORG_GRADLE_PROJECT_appLinkHost.
        manifestPlaceholders["appLinkHost"] = (project.findProperty("appLinkHost") as String?)
            ?.takeIf { it.isNotBlank() } ?: "applinks.invalid"
        manifestPlaceholders["appLabel"] = if (devBuild) "ACM Test" else "Ant Colony"
    }

    signingConfigs {
        if (keystoreProperties.containsKey("storeFile")) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
