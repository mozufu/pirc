plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.mozufu.pirc"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The old app is dev.pirc.mobile.preview; the two install side by side (plans/client.md).
        applicationId = "org.mozufu.pirc"
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Two builds ship for every release (plans/client.md, Embedded Tailscale).
    // Pick one with `--flavor standard|tailscale` together with
    // `--dart-define=PIRC_TAILSCALE=false|true`; the Dart side refuses a mismatch.
    // Until M10 the flavors differ only in application ID.
    flavorDimensions += "network"
    productFlavors {
        create("standard") {
            dimension = "network"
        }
        create("tailscale") {
            dimension = "network"
            applicationIdSuffix = ".tailscale"
            // M10: the embedded node's loopback proxy is plain HTTP; give this
            // flavor its own network_security_config then, not before.
        }
    }

    buildTypes {
        release {
            // Release signing is added with the release pipeline (M11).
            signingConfig = signingConfigs.getByName("debug")
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
