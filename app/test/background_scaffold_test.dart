import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/config/app_config.dart';
import 'package:lan_notepad/src/db/paths.dart';
import 'package:lan_notepad/src/providers.dart';
import 'package:lan_notepad/src/theme/background_scaffold.dart';

/// [BackgroundScaffold] 的行为测试。
///
/// 覆盖两个**实际发生过的 bug**（见 README §7.10）：
/// 1. 背景 `Stack` 曾被塞进 `Scaffold.body`，导致 AppBar / 状态栏区域没有背景
///    → 露出窗口底色，并让 M3 AppBar 的滚动色调动画表现为「标题栏闪烁」；
/// 2. 不设背景图时曾回退到内置图片，而用户要求**纯色**。
void main() {
  /// 用给定的主题配置挂载一个最小的 [BackgroundScaffold]。
  ///
  /// **必须 override `vaultPathsProvider`** —— 它的默认实现是
  /// `throw StateError('必须在 main() 中 override')`，而
  /// `vaultRootProvider` 又 watch 它，所以漏掉就会让整棵树建不起来。
  /// 用 `VaultPaths2.at()`（专为测试提供的构造器）指向一个临时目录。
  Future<void> pump(
    WidgetTester tester, {
    required ThemeConfig theme,
  }) async {
    final tmp = Directory.systemTemp.createTempSync('bgtest');
    addTearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });
    final vault = VaultPaths2.at(tmp);

    await tester.pumpWidget(
      ProviderScope(
        // 不写 `<Override>`：flutter_riverpod 3.5.0 的主入口不再导出该类型
        //（它搬到了 flutter_riverpod/misc.dart），而字面量能自然推断元素类型。
        overrides: [
          appConfigProvider.overrideWith(
            () => _SeedConfig(
              AppConfig(
                deviceId: 'dev-test',
                deviceName: '测试设备',
                theme: theme,
              ),
            ),
          ),
          vaultPathsProvider.overrideWithValue(vault),
        ],
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const BackgroundScaffold(
            appBar: null,
            body: Text('内容'),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('背景层结构', () {
    testWidgets('纯色模式：背景铺在 Scaffold 之外，覆盖整屏', (tester) async {
      await pump(tester, theme: const ThemeConfig());

      final scaffoldElement = tester.element(find.byType(Scaffold));

      // 关键：**背景层必须是 Scaffold 的祖先**，而不是它的 body 内容
      // —— 否则 AppBar / 状态栏区域会没有背景（「标题栏闪烁」的成因之一）。
      //
      // 注意不能简单取 `find.byType(Stack).first`：MaterialApp 内部也有 Stack，
      // 顺序不保证。改为向上遍历 Scaffold 的祖先，找出其中那个由本组件插入的
      // 全屏 Stack（判据：它有一个 ColoredBox 或 Image 作为第一个孩子）。
      bool foundBackgroundAncestor = false;
      scaffoldElement.visitAncestorElements((e) {
        final w = e.widget;
        if (w is Stack) {
          final hasBackgroundLayer = w.children.isNotEmpty &&
              (w.children.first is ColoredBox || w.children.first is Image);
          if (hasBackgroundLayer) {
            foundBackgroundAncestor = true;
            return false;
          }
        }
        return true;
      });

      expect(foundBackgroundAncestor, isTrue,
          reason: '背景层必须包住 Scaffold（含 AppBar），不能只放在 body 里');
    });

    testWidgets('纯色模式：存在不透明的色块兜底，不会露出窗口底色', (tester) async {
      await pump(tester, theme: const ThemeConfig());
      // 纯色时应有 ColoredBox（背景图的替代品）
      expect(find.byType(ColoredBox), findsWidgets);
      // 不应加载任何图片
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('纯色模式：内容照常渲染', (tester) async {
      await pump(tester, theme: const ThemeConfig());
      expect(find.text('内容'), findsOneWidget);
    });
  });

  group('背景三形态', () {
    testWidgets('null → 纯色（不加载图片）', (tester) async {
      await pump(tester, theme: const ThemeConfig());
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('哨兵值 → 尝试加载内置图（测试环境下资源缺失会退化，但不崩）',
        (tester) async {
      await pump(
        tester,
        theme: const ThemeConfig(backgroundImage: kBundledToken),
      );
      await tester.pump();
      // 资源在测试环境未必可用，但必须不抛异常且内容仍在。
      expect(find.text('内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('自选图文件不存在 → 退回纯色，不崩', (tester) async {
      await pump(
        tester,
        theme: const ThemeConfig(backgroundImage: 'theme/nonexistent.jpg'),
      );
      await tester.pump();
      expect(find.text('内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
      // 文件不存在 → 不应构造 Image（退回纯色兜底）
      expect(find.byType(Image), findsNothing);
    });
  });

  group('Scaffold 自身透明', () {
    testWidgets('Scaffold 底色透明，让最外层背景透出来', (tester) async {
      await pump(tester, theme: const ThemeConfig());
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(scaffold.backgroundColor, Colors.transparent);
    });
  });
}

/// 便于在测试里注入初始 [AppConfig] 的 Notifier。
class _SeedConfig extends AppConfigNotifier {
  _SeedConfig(AppConfig seed) : super(seed);
}
