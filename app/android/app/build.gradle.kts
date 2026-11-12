// ⚠️ 必须用 import，不能写 `java.util.Properties()` —— 在 Gradle Kotlin DSL 里
// 标识符 `java` 会被 Gradle 的 `java` 扩展（JavaPluginExtension）遮蔽，
// 于是 `java.util` 报 "Unresolved reference 'util'"。
import java.io.File
import java.util.Properties

plugins {
    id("com.android.application")
    // Flutter Gradle 插件必须在 Android / Kotlin 插件之后应用
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 读取签名配置（可选）──────────────────────────────────────────────
//
// `app/android/key.properties` 由 CI 从 GitHub Secrets 生成，或由开发者本地放置；
// 它被 .gitignore 排除，**不会进仓库**。
//
// 关键设计：**读不到就静默回落**，绝不让缺失的签名配置把 debug/release 构建搞挂。
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        keystorePropsFile.inputStream().use { load(it) }
    }
}

// 仅当 key.properties 存在**且四个必需字段齐全**时才算「有正式签名」。
val hasReleaseKeystore: Boolean = keystorePropsFile.exists() &&
    listOf("storeFile", "storePassword", "keyAlias", "keyPassword")
        .all { !keystoreProps.getProperty(it).isNullOrBlank() }

if (hasReleaseKeystore) {
    logger.lifecycle("[signing] 使用 key.properties 中的正式签名配置")
} else {
    logger.lifecycle("[signing] 未找到 key.properties，release 将使用 Android Debug 证书")
}

android {
    namespace = "com.example.lan_notepad"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // super_clipboard / image_picker 等插件用到 Java 8+ 新 API
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.example.lan_notepad"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // ── 签名配置 ──────────────────────────────────────────────────────
    //
    // 有 `app/android/key.properties`（+ storeFile 指向的 keystore）就用**正式签名**；
    // 没有就回落到 **Android Debug 证书**。
    //
    // 为什么要这样写：
    //   仓库是**公开的**，签名密钥**绝不能提交**（.gitignore 已排除 *.jks / *.keystore /
    //   key.properties）。CI 上由 workflow 从 Secrets 解码出 keystore 并生成
    //   key.properties —— 未配置 Secrets 时该文件不存在，于是自动走回落分支。
    //
    // ⚠️ 关于「回落到底 debug 证书」的代价（实测，2026-11-12）：
    //   CI runner 上**没有预置** debug keystore（已核对 actions/runner-images 仓库，
    //   脚本里无任何 keystore/androiddebugkey 痕迹），AGP 会用
    //   KeystoreHelper.createDebugStore() 现场生成一个 —— 而该函数内部是
    //   `KeyPairGenerator.generateKeyPair()`，**每次调用都生成新的随机密钥对**。
    //   本地实测两次生成，证书指纹完全不同：
    //     ks1 SHA-256: CA:11:E1:6C:CE:A0:E2:8C:...      ks2: 5F:B5:4D:64:59:23:C5:8B:...
    //   → 同一个 CI 上跑两次 release，**签名不同 → 无法互相覆盖安装**。
    //   所以「零配置直接发 release」只适合「自己用、装一次」；
    //   要做能持续升级的分发，必须配 Secrets（见 workflow 的
    //   ANDROID_KEYSTORE_BASE64 等，以及 README 的说明）。
    signingConfigs {
        // 只有配好了正式签名才创建 —— 否则这里是空操作，release 走 debug 证书回落。
        if (hasReleaseKeystore) {
            create("release") {
                val configured = File(keystoreProps.getProperty("storeFile"))
                storeFile = if (configured.isAbsolute) configured
                            else rootProject.file(configured.path)
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 有 key.properties → 正式签名；否则回落 debug 证书（可构建/可安装/可分发）。
            signingConfig = if (hasReleaseKeystore) {
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
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
