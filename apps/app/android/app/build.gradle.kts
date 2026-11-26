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

    // Robolectric tests read the app's strings and layouts (notifications, M8 step 3).
    testOptions {
        unitTests {
            isIncludeAndroidResources = true
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

// The Kotlin side of M8, added once (the versions of the old app).
dependencies {
    implementation("com.squareup.okhttp3:okhttp:5.1.0")
    implementation("org.unifiedpush.android:connector:3.3.5") {
        // flutter_secure_storage (macOS keeps it) brings tink-android; the connector's
        // plain tink would duplicate its classes.
        exclude(group = "com.google.crypto.tink", module = "tink")
    }
    // The connector needs Tink; take the Android build directly, at the version
    // flutter_secure_storage brings, instead of through that plugin.
    implementation("com.google.crypto.tink:tink-android:1.23.0")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    implementation("androidx.javascriptengine:javascriptengine:1.1.1")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16")
    testImplementation("com.squareup.okhttp3:mockwebserver3:5.1.0")
}

// Android assets are unavailable in local JVM tests. Use OkHttp's published JVM
// runtime (including its public suffix list); the app keeps okhttp-android.
configurations.matching { it.name.endsWith("UnitTestCompileClasspath") || it.name.endsWith("UnitTestRuntimeClasspath") }.configureEach {
    resolutionStrategy.dependencySubstitution {
        substitute(module("com.squareup.okhttp3:okhttp")).using(module("com.squareup.okhttp3:okhttp-jvm:5.1.0"))
    }
}

// With Android resources in unit tests, packaging them reads the merged assets that the
// Flutter plugin's copyFlutterAssets* tasks also write. Order the two without making the
// Kotlin tests build the Dart side.
tasks.configureEach {
    val variant = Regex("package(\\w+)UnitTestForUnitTest").matchEntire(name)?.groupValues?.get(1) ?: return@configureEach
    mustRunAfter("copyFlutterAssets$variant")
}
