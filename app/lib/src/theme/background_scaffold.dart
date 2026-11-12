import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../config/app_config.dart';
import '../providers.dart';

/// 所有页面共用的脚手架：背景图铺底 + 内容浮于其上。
///
/// 背景图位于 `notepad/theme/`，**不在** `assets/images/` 下，
/// 因此不参与同步、也不会被图片 GC 删除。
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

    Widget content = body;

    final bg = theme.backgroundImage;
    if (bg != null && vaultRoot != null) {
      final file = File(p.join(vaultRoot, bg));
      if (file.existsSync()) {
        content = Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Image.file(
              file,
              fit: BoxFit.cover,
              // 背景图加载失败不应让页面崩掉。
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            ),
            // 透明度通过覆盖一层主题底色的半透明膜实现，
            // 这样文字对比度可控，且不依赖图片本身。
            Container(
              color: (Theme.of(context).brightness == Brightness.dark
                      ? Colors.black
                      : Colors.white)
                  .withValues(alpha: 1 - theme.backgroundOpacity),
            ),
            content,
          ],
        );
      }
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: appBar,
      floatingActionButton: floatingActionButton,
      body: content,
    );
  }
}

/// 主题配置（供 UI 读取 / 修改）。
ThemeConfig themeConfigFrom(AppConfig cfg) => cfg.theme;
