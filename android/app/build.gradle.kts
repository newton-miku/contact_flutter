import java.util.Properties

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

// 发布签名：从 android/key.properties 读取（该文件与 keystore 都在 .gitignore 里，不入库）。
// 本机由开发者放置；CI 由 workflow 用 Secrets 生成同名文件。
// 未配置时：release 构建会以明确报错终止（绝不静默退回 debug 测试签名）。
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { load(it) }
    }
}
val hasReleaseSigning = keystoreProps.getProperty("storeFile") != null

android {
    namespace = "com.newtonmiku.contact_flutter"
    compileSdk = flutter.compileSdkVersion
    // NDK 版本必须钉定：本项目虽无 C/C++ 源码，但 mobile_scanner(ML Kit) 等插件带预编译 .so，
    // AGP 打包时要用 NDK 里的 strip 工具处理它们，未配置会直接报 “NDK not configured”。
    // CI 侧已加「接受 SDK 许可 + 缓存 NDK」两步，首次运行会自动下载。
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

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                // storeFile 相对 android/ 目录（key.properties 与本 keystore 同级）
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
                enableV1Signing = true
                enableV2Signing = true
            }
        }
    }

    buildTypes {
        release {
            // 正式发布签名（不再使用 debug 测试签名）。
            // 未配置 key.properties 时保留 debug 仅为「能配置成功」，真正的 release 打包
            // 会在下面的 taskGraph 检查里直接失败并提示配置方式，避免误分发测试签名包。
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
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

// 只在真正要出 release 包时校验签名配置，避免影响 debug 构建 / analyze / test。
gradle.taskGraph.whenReady {
    val buildingRelease = allTasks.any {
        it.name == "assembleRelease" || it.name == "bundleRelease"
    }
    if (buildingRelease && !hasReleaseSigning) {
        throw GradleException(
            "未配置发布签名，已中止 release 打包。\n" +
                "  本机：在 android/key.properties 写入 storeFile/storePassword/keyAlias/keyPassword；\n" +
                "  CI ：在仓库 Secrets 配置 KEYSTORE_BASE64 / KEYSTORE_PASSWORD / KEY_ALIAS / KEY_PASSWORD。"
        )
    }
}
