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
