import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.mangacolorizer.manga_colorizer_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mangacolorizer.manga_colorizer_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    val keyPropsFile = rootProject.file("key.properties")
    val useReleaseSigning = keyPropsFile.exists()

    if (useReleaseSigning) {
        val keyProps = Properties().apply { load(FileInputStream(keyPropsFile)) }
        signingConfigs {
            create("release") {
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
                storeFile = rootProject.file(keyProps.getProperty("storeFile")!!)
                storePassword = keyProps.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties 时用自有发布密钥签名；否则回退 debug 密钥（本地/无密钥 CI 仍可构建）
            signingConfig = if (useReleaseSigning) {
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

dependencies {
    // ORT 运行时钉在 1.27.0（flutter_onnxruntime 1.9.0 默认带 1.28.0）。
    // 依据：v0.5.13/14 真机两轮复现，:inference 进程恒死在首个 ORT Run
    // 内部（[backend] SAM Run 开始 → 无 Run 完成；死亡时 RSS≈517-594MB，
    // 15.3GB 设备远离 LMK 门槛；arena 开/关均复现）——指向 1.28.0（.0
    // 大版本，ONNX 1.22/protobuf 6 升级线）ARM64 原生缺陷。桌面 .venv
    // onnxruntime 1.24.4 跑同一模型全绿。1.27.0 是 1.28 之前最后稳定线。
    // resolutionStrategy.force 仲裁传递依赖版本，优先于插件 pom 声明——
    // 这是升降级插件携带的原生库而不 fork 插件的标准手法。
    configurations.all {
        resolutionStrategy {
            force("com.microsoft.onnxruntime:onnxruntime-android:1.27.0")
        }
    }
}


