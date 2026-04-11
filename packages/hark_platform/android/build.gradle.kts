import org.jetbrains.kotlin.gradle.dsl.JvmTarget

group = "com.oacp.hark_platform"
version = "1.0"

buildscript {
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.2.20")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

kotlin {
    compilerOptions {
        jvmTarget = JvmTarget.fromTarget(JavaVersion.VERSION_17.toString())
    }
}

android {
    namespace = "com.oacp.hark_platform"
    compileSdk = 34

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 26
    }
}

dependencies {
    // Wake word detection: openWakeWord (Apache 2.0) + Silero VAD (MIT)
    implementation("xyz.rementia:openwakeword:0.1.4")
    implementation("com.github.gkonovalov.android-vad:silero:2.0.10")
    // Force single ONNX Runtime version across all transitive deps.
    // App uses 1.23.0 for EmbeddingGemma; openWakeWord uses 1.18.0;
    // android-vad uses 1.22.0. All are compatible with 1.23.0.
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.23.0")
    // Kotlin coroutines for WakeWordEngine's Flow-based API
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
