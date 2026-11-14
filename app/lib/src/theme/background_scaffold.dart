import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import '../providers.dart';

/// 内置背景资源（打包进 APK）。
///
/// 由 `tools/render-assets.sh` 从 `assets/branding/source.jpg` 生成。
/// **不是默认背景** —— 只有用户在设置里显式选择它才会使用（见 [kBundledToken]）。
const String kBundledBackground = 'assets/backgrounds/app_bg.jpg';

/// [ThemeConfig.backgroundImage] 取此值时表示「使用内置背景图」。
///
/// 用带冒号的哨兵值而不是新增布尔字段：冒号在真实文件名里非法，
/// 因此不会与用户自选的文件相对路径冲突，也不必改动配置的序列化格式
/// （旧版本配置文件解析后仍是 `null`，即纯色 —— 行为自然向后兼容）。
const String kBundledToken = ':bundled:';

/// 页面骨架：全屏背景 + 内容浮于其上。
///
/// ## 背景如何覆盖整屏（曾经出错的地方）
///
/// 背景层放在 **`Scaffold` 之外**的 [Stack] 里，而不是塞进 `Scaffold.body`。
/// 早先版本把背景放进 `body`，导致 **AppBar 与状态栏区域没有任何背景**，
/// 直接露出窗口底色 —— 这是「标题栏闪烁」的一半原因
/// （另一半是 M3 AppBar 的滚动色调动画，已在 `buildThemeData` 里关掉）。
///
/// ## 背景的三种形态
///
/// | [ThemeConfig.backgroundImage] | 表现 |
/// | --- | --- |
/// | `null`（默认） | **纯色**（主题 `colorScheme.surface`） |
/// | [kBundledToken] | 内置背景图 + 半透明膜 |
/// | 其他字符串 | 用户自选图片（相对笔记库根目录）+ 半透明膜 |
///
/// 自选图文件不存在时（例如被外部删除）**回退为纯色**，不显示破损图。
class BackgroundScaffold extends ConsumerWidget {
  const BackgroundScaffold({
    super.key,
    required this.body,
    this.appBar,
    this.floatingActionButton,
  });

  final Widget body;
  final PreferredSizeWidget? appBar;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeConfigProvider);
    final vaultRoot = ref.watch(vaultRootProvider);
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // ── 解析背景图（可能为 null = 纯色）────────────────────────────────
    Widget? image;
    final spec = theme.backgroundImage;
    if (spec == kBundledToken) {
      image = Image.asset(
        kBundledBackground,
        fit: BoxFit.cover,
        // 资源缺失（例如忘记跑 tools/render-assets.sh）时退化为纯色。
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      );
    } else if (spec != null && vaultRoot != null) {
      final file = File(p.join(vaultRoot, spec));
      if (file.existsSync()) {
        image = Image.file(
          file,
          fit: BoxFit.cover,
          // 背景图加载失败不应让页面崩掉。
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        );
      }
    }

    // 半透明膜：把背景图压到用户设定的不透明度，保证文字对比度可控
    // （不依赖图片本身的明暗）。纯色模式不需要 —— 那个颜色本身就是最终底色。
    final scrim = Container(
      color: (isDark ? Colors.black : Colors.white)
          .withValues(alpha: 1 - theme.backgroundOpacity),
    );

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // 底层：背景图，或纯色兜底。这一层铺满整屏（含 AppBar / 状态栏），
        // 所以不存在「某块区域没背景、露出窗口底色」的可能。
        if (image != null) image else ColoredBox(color: scheme.surface),
        if (image != null) scrim,
        Scaffold(
          // Scaffold 自身透明，让上方的背景层透出来。
          backgroundColor: Colors.transparent,
          appBar: appBar,
          floatingActionButton: floatingActionButton,
          body: body,
        ),
      ],
    );
  }
}

/// 主题配置（供 UI 读取 / 修改）。
ThemeConfig themeConfigFrom(AppConfig cfg) => cfg.theme;
