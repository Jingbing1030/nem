import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import '../providers.dart';

/// 内置背景资源（打包进 APK）。
///
/// 由 `tools/render-assets.sh` 从 `assets/branding/source.jpg` 生成。
const String kBundledBackground = 'assets/backgrounds/app_bg.jpg';

/// 所有页面共用的脚手架：背景图铺底 + 内容浮于其上。
///
/// 背景优先级：
/// 1. 用户自选背景（`notepad/theme/` 下的文件）—— 不参与同步与图片 GC；
/// 2. **内置背景**（[kBundledBackground]）—— 默认观感；
/// 3. 都没有 → 纯主题底色（此时 [buildThemeData] 已给出不透明的 surface）。
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
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // 解析出实际要用的背景 widget（用户图优先，其次内置图）。
    Widget? background;
    final custom = theme.backgroundImage;
    if (custom != null && vaultRoot != null) {
      final file = File(p.join(vaultRoot, custom));
      if (file.existsSync()) {
        background = Image.file(
          file,
          fit: BoxFit.cover,
          // 背景图加载失败不应让页面崩掉。
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      }
    }
    background ??= Image.asset(
      kBundledBackground,
      fit: BoxFit.cover,
      // 资源缺失（例如忘记跑生成脚本）时退化为纯色，不影响可用性。
      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
    );

    // 半透明膜：把背景压到用户设定的不透明度，保证文字对比度可控
    // （不依赖图片本身的明暗）。
    final scrim = Container(
      color: (isDark ? Colors.black : Colors.white)
          .withValues(alpha: 1 - theme.backgroundOpacity),
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: appBar,
      floatingActionButton: floatingActionButton,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          background,
          scrim,
          body,
        ],
      ),
    );
  }
}

/// 主题配置（供 UI 读取 / 修改）。
ThemeConfig themeConfigFrom(AppConfig cfg) => cfg.theme;
