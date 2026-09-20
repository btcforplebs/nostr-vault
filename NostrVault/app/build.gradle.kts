import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
    id("com.google.dagger.hilt.android")
    id("com.google.devtools.ksp")
}

val localProps = Properties().apply {
    val f = rootProject.file("local.properties")
    if (f.exists()) load(f.inputStream())
}

android {
    namespace = "com.nostrvault"
    compileSdk = 35

    // Only wire the release signer when local.properties actually carries the
    // keystore. The unconditional `as String` casts here threw at configuration
    // time on any checkout without it, which failed even `compileDebugKotlin` —
    // a debug build has no business needing the release keystore.
    val hasReleaseKeystore = listOf(
        "KEYSTORE_PATH", "KEYSTORE_PASSWORD", "KEY_ALIAS", "KEY_PASSWORD",
    ).all { localProps[it] != null }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(localProps["KEYSTORE_PATH"] as String)
                storePassword = localProps["KEYSTORE_PASSWORD"] as String
                keyAlias = localProps["KEY_ALIAS"] as String
                keyPassword = localProps["KEY_PASSWORD"] as String
            }
        }
    }

    defaultConfig {
        applicationId = "com.nostrvault.app"
        minSdk = 26
        targetSdk = 35
        versionCode = 15
        versionName = "2.7.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"

        ndk {
            abiFilters += listOf("arm64-v8a")
        }

        vectorDrawables {
            useSupportLibrary = true
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            // Unsigned without a keystore; `assembleRelease` then produces an
            // unsigned APK instead of failing the whole configuration phase.
            if (hasReleaseKeystore) signingConfig = signingConfigs.getByName("release")
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
        debug {
            isMinifyEnabled = false
            // applicationIdSuffix = ".debug"  // Commented out to allow debug builds to replace release builds
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests {
            // android.util.Log throws "not mocked" by default, which fails any
            // JVM test that walks through code that logs — which is most of it.
            isReturnDefaultValues = true
        }
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
        // Keep the Go .so files
        jniLibs {
            keepDebugSymbols += "**/*.so"
        }
    }

    // Wire Go relay build as a pre-build step
    // Uncomment when NDK is installed and Go cross-compilation is configured
    // tasks.register<Exec>("buildGoRelay") {
    //     workingDir = rootDir
    //     commandLine("bash", "build_haven_android.sh")
    // }
    // tasks.named("preBuild") { dependsOn("buildGoRelay") }

    externalNativeBuild {
        cmake {
            path = file("src/main/CMakeLists.txt")
            version = "3.22.1"
        }
    }
}

dependencies {
    // ---- Compose BOM ----
    val composeBom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    // Compose UI
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.animation:animation")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.8.5")

    // Lifecycle + ViewModel
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
    implementation("androidx.lifecycle:lifecycle-service:2.8.7")

    // Activity
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")

    // Fragment (FragmentActivity host) + Biometric (reveal-key auth)
    implementation("androidx.fragment:fragment-ktx:1.8.5")
    implementation("androidx.biometric:biometric:1.1.0")

    // ---- Dependency Injection (Hilt) ----
    implementation("com.google.dagger:hilt-android:2.53.1")
    ksp("com.google.dagger:hilt-android-compiler:2.53.1")
    implementation("androidx.hilt:hilt-navigation-compose:1.2.0")

    // ---- Networking ----
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    // ---- Image Loading (Coil) ----
    implementation("io.coil-kt:coil-compose:2.7.0")
    implementation("io.coil-kt:coil-gif:2.7.0")
    implementation("io.coil-kt:coil-video:2.7.0")

    // ---- Video (ExoPlayer / Media3) ----
    implementation("androidx.media3:media3-exoplayer:1.5.1")
    implementation("androidx.media3:media3-ui:1.5.1")
    // Live streams are HLS (.m3u8); ExoPlayer needs this to open one.
    implementation("androidx.media3:media3-exoplayer-hls:1.5.1")

    // ---- JSON ----
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")

    // ---- Coroutines ----
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")

    // ---- Encrypted Storage ----
    implementation("androidx.security:security-crypto:1.1.0-alpha06")
    implementation("androidx.datastore:datastore-preferences:1.1.1")

    // ---- QR Code ----
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")

    // ---- Home-screen widgets (Glance) ----
    implementation("androidx.glance:glance-appwidget:1.1.1")
    implementation("androidx.glance:glance-material3:1.1.1")

    // ---- Markdown ----
    implementation("com.github.jeziellago:compose-markdown:0.5.4")

    // ---- Permissions ----
    implementation("com.google.accompanist:accompanist-permissions:0.36.0")

    // ---- Firebase (Push Notifications) ----
    // Uncomment when google-services.json is added
    // implementation("com.google.firebase:firebase-messaging-ktx:24.1.0")

    // ---- Testing ----
    testImplementation("junit:junit:4.13.2")
    testImplementation("io.mockk:mockk:1.13.13")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.6.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
