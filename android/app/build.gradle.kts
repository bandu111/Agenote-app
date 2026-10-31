import java.util.Base64

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 集成测试单独安装，测试驱动的卸载流程不会碰到用户正在使用的应用。
// Flutter test 有时传入临时 bootstrap 作为 target，不能只检查文件名。
val integrationDefine = providers.gradleProperty("dart-defines").orNull.orEmpty().split(",").any {
    runCatching { String(Base64.getDecoder().decode(it)) == "YANSHU_INTEGRATION_TEST=true" }.getOrDefault(false)
}
val integrationBuild = integrationDefine || providers.gradleProperty("target").orNull?.contains("integration_test") == true

android {
    namespace = "com.example.yanshu"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.yanshu"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // 普通构建统一项目包名；服务地址、令牌和资料目录仍按环境隔离。
    flavorDimensions += "environment"
    productFlavors {
        create("local") {
            dimension = "environment"
            if (integrationBuild) applicationIdSuffix = ".integration"
            manifestPlaceholders["appLabel"] = if (integrationBuild) "Agenote·本地测试" else "Agenote·本地"
        }
        create("cloud") {
            dimension = "environment"
            applicationIdSuffix = if (integrationBuild) ".cloud.integration" else ""
            manifestPlaceholders["appLabel"] = if (integrationBuild) "Agenote·云端测试" else "Agenote"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
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

dependencies {
    implementation(files("libs/soninote/pnote_20260827161403.aar"))
    implementation("org.xutils:xutils:3.3.40")
    implementation("androidx.appcompat:appcompat:1.0.0")
    implementation("com.squareup.okhttp3:logging-interceptor:3.9.0")
    implementation("com.polidea.rxandroidble2:rxandroidble:1.17.2")
    implementation("io.reactivex.rxjava2:rxandroid:2.1.1")
    implementation("io.reactivex.rxjava2:rxjava:2.2.8")
    implementation("com.squareup.retrofit2:retrofit:2.5.0")
    implementation("com.squareup.retrofit2:adapter-rxjava2:2.5.0")
    implementation("com.squareup.retrofit2:converter-gson:2.5.0")
    implementation("com.squareup.retrofit2:converter-scalars:2.5.0")
    implementation("io.reactivex.rxjava3:rxjava:3.1.8")
    implementation("org.greenrobot:eventbus:3.3.1")
    implementation("org.greenrobot:greendao:3.2.2")
    implementation("com.koushikdutta.async:androidasync:3.1.0")
}
