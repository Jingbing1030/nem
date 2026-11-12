import org.gradle.api.tasks.Delete
import java.io.File

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

/*
 * ── 补上 Flutter 漏做的那次 KGP apply（针对 :file_picker）────────────────
 *
 * 为什么需要（实测 + 源码依据，2026-11-12）：
 *
 * Flutter 3.50 的 FlutterPluginUtils.detectApplyingKotlinGradlePlugin 里有段兜底：
 *     if (!isBuiltInKotlinEnabled(project, agpVersion) && !pluginState.hasKgpPlugin) {
 *         pluginManager.apply("kotlin-android")     // 帮没 apply KGP 的插件补上
 *     }
 * 但 `hasKgpPlugin` 是靠**正则扫 build 脚本文本**得出的（kgpRegexGroovy），
 * 它只能做行首文本匹配，**看不懂 if 条件**：
 *     file_picker 11.0.3/android/build.gradle:
 *         if (!isAgp9OrAbove) {                      // ← 正则看不见这个 if
 *             apply plugin: 'org.jetbrains.kotlin.android'
 *         }
 * 于是 Flutter 误判 "它已经 apply 了 KGP" → 跳过兜底。
 * 而运行时 AGP=9 → isAgp9OrAbove=true → file_picker 自己**也**跳过。
 * 结果：file_picker 的 Kotlin 源码（FilePickerPlugin.kt）无人编译，
 *       Java 侧的 GeneratedPluginRegistrant 报 "cannot find symbol: class FilePickerPlugin"。
 *
 * 这里显式补上那次 apply。用 plugins.withId 保证顺序（KGP 需要 Android 插件已就位），
 * 也保证只在 file_picker 被真正加入构建时才生效。
 *
 * 注意：不能改成 android.builtInKotlin=true 来"绕"这个问题 ——
 * AGP 9 在 builtInKotlin=true 时会对任何 apply KGP 的模块直接抛
 * IllegalStateException，而 device_info_plus 等插件是**无条件** apply 的。
 * 两类插件互斥，只能这样逐个补。
 */
subprojects {
    if (name == "file_picker") {
        plugins.withId("com.android.library") {
            pluginManager.apply("org.jetbrains.kotlin.android")
        }
    }
}

/*
 * ── 统一所有子项目的 Kotlin jvmTarget = 17 ────────────────────────────────
 *
 * 背景（实测，2026-11-12）：
 *
 * release 构建要求 **JDK 21**（AGP 9.3.1 的 lintVitalRelease 会调用 JDK 21 才有的
 * List.removeLast()，JDK 17 下 NoSuchMethodError）。换到 JDK 21 后暴露第二个问题：
 *
 *   Execution failed for task ':file_picker:compileReleaseKotlin'
 *   > Inconsistent JVM-target compatibility detected for tasks
 *     'compileReleaseJavaWithJavac' (17) and 'compileReleaseKotlin' (21).
 *
 * 原因：Kotlin 插件在未显式指定 jvmTarget 时**跟随 JDK 版本**（JDK 21 → 21），
 * 而 Java 侧由各插件 build.gradle 的 compileOptions 固定 17。
 * file_picker 11.0.3 的 kotlinOptions 写在 `if (!isAgp9OrAbove) { }` 里，
 * AGP 9 下被跳过 → 用不上那个 17。
 *
 * 解法：给这些子项目显式设 kotlin.compilerOptions.jvmTarget = JVM_17。
 * 统一到 17（与 app 模块的 compileOptions 一致），只统一、不抬升，风险最小。
 *
 * 说明：这里只处理需要修正的插件（白名单），而不是所有子项目 ——
 * 因为对各插件 Kotlin 扩展做反射配置既脆弱又难读，
 * 明确的名单更容易理解和维护。名单来源：实测报错 + 扫描 compileOptions 与
 * jvmTarget 不一致的插件。
 */
val kotlinJvmTargetFixPlugins = setOf(
    "file_picker",                 // kotlinOptions 在 if(!isAgp9OrAbove) 内，AGP 9 下被跳过
    "device_info_plus",
    "flutter_image_compress_common",
)

subprojects {
    if (name in kotlinJvmTargetFixPlugins) {
        /*
         * 必须用 plugins.withId 钩子，不能直接配置：
         * subprojects {} 在校验阶段就执行了，而那时插件的 build.gradle 还没被评估、
         * Kotlin 扩展尚不存在 —— 直接 extensions.configure 会抛
         * "Extension of type 'KotlinAndroidProjectExtension' does not exist"。
         * withId 的回调在插件被应用后才触发，时机正确。
         */
        plugins.withId("org.jetbrains.kotlin.android") {
            // Kotlin 官方 DSL（新版）。Kotlin 2.x 里 kotlinOptions 已废弃且会编译报错。
            extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
                compilerOptions {
                    jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
                }
            }
        }
    }
}
