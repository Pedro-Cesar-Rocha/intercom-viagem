plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.pedrocesar.comboio"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.pedrocesar.comboio"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Só celulares (ARM). O WebRTC traz também bibliotecas x86/x86_64, que só
    // aumentariam o APK. (O plugin do Flutter redefine abiFilters, então o
    // corte é feito no empacotamento.)
    packaging {
        jniLibs {
            excludes += setOf("**/x86_64/**", "**/x86/**")
        }
    }

    // Chave fixa do projeto: cada build novo instala por cima do anterior.
    signingConfigs {
        create("comboio") {
            storeFile = file("../../ci/debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        debug {
            signingConfig = signingConfigs.getByName("comboio")
        }
        release {
            signingConfig = signingConfigs.getByName("comboio")
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
