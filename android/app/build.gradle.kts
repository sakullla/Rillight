import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release builds are signed with the keystore described by android/key.properties
// (storeFile/keyAlias/storePassword/keyPassword). CI injects it from repository
// secrets; local release builds must create it themselves.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties().apply {
    if (keystorePropertiesFile.exists()) {
        keystorePropertiesFile.inputStream().use { load(it) }
    }
}

android {
    namespace = "com.rillight.rillight"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.rillight.rillight"
        // Opt-in validation builds have private accounts, settings and snapshots.
        if (providers.gradleProperty("rillightValidation").orNull == "true") {
            applicationIdSuffix = ".validation"
        }
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 36
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (keystorePropertiesFile.exists()) {
                fun requiredProperty(name: String): String =
                    keystoreProperties.getProperty(name)
                        ?: throw GradleException("android/key.properties is missing '$name'")

                keyAlias = requiredProperty("keyAlias")
                keyPassword = requiredProperty("keyPassword")
                storeFile = file(requiredProperty("storeFile"))
                storePassword = requiredProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Release builds must be signed with the keystore from
            // android/key.properties; see checkReleaseSigning below for the
            // explicit failure when it is missing.
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// Fail release builds with a readable error when signing material is absent,
// instead of silently falling back to the debug key or an obscure AGP error.
val checkReleaseSigning = tasks.register("checkReleaseSigning") {
    doLast {
        if (!keystorePropertiesFile.exists()) {
            throw GradleException(
                "android/key.properties not found. Release builds must be signed: " +
                    "create android/key.properties with storeFile, storePassword, " +
                    "keyAlias and keyPassword pointing at a valid keystore.",
            )
        }
        val storeFile = keystoreProperties.getProperty("storeFile")?.let { project.file(it) }
        if (storeFile == null || !storeFile.exists()) {
            throw GradleException(
                "Keystore file not found: ${storeFile?.path ?: "(storeFile missing in key.properties)"}. " +
                    "Check storeFile in android/key.properties.",
            )
        }
    }
}
tasks.matching { it.name == "assembleRelease" || it.name == "packageRelease" }.configureEach {
    dependsOn(checkReleaseSigning)
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
