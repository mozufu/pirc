plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("org.jetbrains.kotlin.plugin.serialization")
}

android {
    buildFeatures { buildConfig = true }
    sourceSets.getByName("main").java.srcDir(layout.buildDirectory.dir("generated/pircCore").get().asFile)
    namespace = "dev.pirc.pirc_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.pirc.mobile.preview"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
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
    implementation("com.squareup.okhttp3:okhttp:5.1.0")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")
    implementation("org.unifiedpush.android:connector:3.3.5")
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
    testImplementation("junit:junit:4.13.2")
    implementation("androidx.core:core-ktx:1.17.0")
}

val sharedCore = tasks.register<Sync>("syncPircCore") {
    from(System.getenv("PIRC_ANDROID_SOURCE") ?: "../../../android/app/src/main/java") {
        include("dev/pirc/android/core/**", "dev/pirc/android/push/PushRegistration.kt")
    }
    into(layout.buildDirectory.dir("generated/pircCore"))
}
tasks.named("preBuild").configure { dependsOn(sharedCore) }

// Run the original API and reducer contract tests against the exact shared sources.
val syncCoreTests = tasks.register<Sync>("syncPircCoreTests") {
    from(System.getenv("PIRC_ANDROID_TEST_SOURCE") ?: "../../../android/app/src/test/java") {
        include("dev/pirc/android/core/PircApiTest.kt", "dev/pirc/android/core/PairingLinkTest.kt", "dev/pirc/android/core/ControlTest.kt", "dev/pirc/android/core/SchedulesTest.kt", "dev/pirc/android/core/timeline/TimelineFixturesTest.kt")
    }
    into(layout.buildDirectory.dir("generated/pircCoreTests"))
}
android.sourceSets.getByName("test").java.srcDir(layout.buildDirectory.dir("generated/pircCoreTests").get().asFile)
tasks.named("preBuild").configure { dependsOn(syncCoreTests) }
tasks.withType<Test>().configureEach {
    systemProperty("pirc.fixtures", System.getenv("PIRC_FIXTURES") ?: file("../../../../fixtures").absolutePath)
}
dependencies {
    testImplementation("com.squareup.okhttp3:mockwebserver3:5.1.0")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
}
