plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 应用安装身份：默认 com.newtonmiku.contact_flutter；用环境变量 APP_ID_SUFFIX 追加发布线后缀。
//   - 本地/示例打包：APP_ID_SUFFIX=_demo flutter build apk ...
//   - GitHub Actions：仓库 Variables 配 APP_ID_SUFFIX（未配 = 无后缀），见 .github/workflows/build.yml
// 注意：applicationId 不同 = 设备上视为不同 App，无法互相覆盖安装（激活状态不通用）。
val appIdSuffix = System.getenv("APP_ID_SUFFIX") ?: ""

android {
    namespace = "com.newtonmiku.contact_flutter"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "30.0.15729638"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.newtonmiku.contact_flutter" + appIdSuffix
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
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
