import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/config/app_config.dart';
import 'package:lan_notepad/src/theme/background_scaffold.dart';
import 'package:lan_notepad/src/theme/theme_config_provider.dart';

/// 主题构造与深浅色解析的测试。
///
/// 覆盖的是两个**实际发生过的 bug**（见 README §7.10）：
/// 1. 无背景图时脚手架底色被无条件设为透明 → 露出 Android 窗口底色，
///    深色模式下表现为「打开后突然变成纯黑」；
/// 2. `textColor` 默认 `'#000000'` → 深色模式黑字黑底看不见。
void main() {
  group('resolveBrightness：system 解析', () {
    test('light / dark 直接给出确定值，不受系统影响', () {
      expect(
        resolveBrightness(BrightnessMode.light, Brightness.dark),
        Brightness.light,
        reason: '显式选浅色时，系统是深色也应保持浅色',
      );
      expect(
        resolveBrightness(BrightnessMode.dark, Brightness.light),
        Brightness.dark,
        reason: '显式选深色时，系统是浅色也应保持深色',
      );
    });

    test('system 跟随系统亮度', () {
      expect(
        resolveBrightness(BrightnessMode.system, Brightness.dark),
        Brightness.dark,
      );
      expect(
        resolveBrightness(BrightnessMode.system, Brightness.light),
        Brightness.light,
      );
    });

    test('非法取值按跟随系统处理（脏配置不该把界面搞坏）', () {
      expect(resolveBrightness('', Brightness.dark), Brightness.dark);
      expect(resolveBrightness('DARK', Brightness.light), Brightness.light);
      expect(resolveBrightness('nonsense', Brightness.dark), Brightness.dark);
    });
  });

  group('parseHexColor', () {
    test('接受带 # / 不带 # / 8 位 ARGB', () {
      expect(parseHexColor('#FF0000'), const Color(0xFFFF0000));
      expect(parseHexColor('FF0000'), const Color(0xFFFF0000));
      expect(parseHexColor('#80FF0000'), const Color(0x80FF0000));
    });

    test('非法输入返回 fallback，不抛异常', () {
      expect(parseHexColor('', fallback: const Color(0xFF123456)),
          const Color(0xFF123456));
      expect(parseHexColor('#GGG', fallback: const Color(0xFF123456)),
          const Color(0xFF123456));
      expect(parseHexColor('#12345', fallback: const Color(0xFF123456)),
          const Color(0xFF123456));
    });
  });

  group('buildThemeData：脚手架底色', () {
    // Scaffold 底色透明，由 BackgroundScaffold 在最外层铺一层**全覆盖**内容
    // （纯色 / 内置图 / 自选图）。纯黑问题的修复就是靠「总有一层铺满整屏」。
    test('scaffold 底色透明（背景由 BackgroundScaffold 铺设）', () {
      for (final b in [Brightness.light, Brightness.dark]) {
        final t = buildThemeData(const ThemeConfig(), brightness: b);
        expect(t.scaffoldBackgroundColor, Colors.transparent);
      }
    });

    // canvasColor 刻意**保持默认**（= scheme.surface）：它影响 Drawer、
    // 弹出菜单、BottomSheet 等浮层的默认底色。若把它也设成透明，
    // 这些浮层会透出下层内容。只有 Scaffold 需要透明。
    test('canvasColor 保持不透明（浮层需要实底）', () {
      for (final b in [Brightness.light, Brightness.dark]) {
        final t = buildThemeData(const ThemeConfig(), brightness: b);
        expect(t.canvasColor, isNot(Colors.transparent),
            reason: '设成透明会让 Drawer/菜单/BottomSheet 透出下层内容');
      }
    });

    test('深色色板不是纯黑（与 Android 窗口底色的差异所在）', () {
      final dark = buildThemeData(
        const ThemeConfig(),
        brightness: Brightness.dark,
      );
      // M3 深色 surface 实测为 #111418，而 Theme.Black 的 colorBackground
      // 是纯黑 #000000 —— 早期版本透出的正是后者，故看起来"纯黑"。
      expect(dark.colorScheme.surface, isNot(const Color(0xFF000000)));
    });

    test('内置背景资源路径与哨兵值已声明', () {
      expect(kBundledBackground, 'assets/backgrounds/app_bg.jpg');
      // 哨兵用冒号包裹：冒号在真实文件名里非法，故不会与用户的相对路径冲突。
      expect(kBundledToken, ':bundled:');
      expect(kBundledToken.contains('/'), isFalse,
          reason: '哨兵不应像文件路径，否则可能被误当作真实文件去解析');
    });

    test('默认（backgroundImage = null）表示纯色', () {
      // 用户要求：不设背景图片时用纯色，而不是回退到内置图片。
      expect(const ThemeConfig().backgroundImage, isNull);
    });

    test('哨兵值不会被误判为纯色', () {
      const t = ThemeConfig(backgroundImage: kBundledToken);
      expect(t.backgroundImage, isNotNull);
      expect(t.backgroundImage, isNot('theme/bg.jpg'));
    });
  });

  group('buildThemeData：文字颜色', () {
    test('textColor 为 null（自动）时按深浅色选黑/白', () {
      final light = buildThemeData(
        const ThemeConfig(),
        brightness: Brightness.light,
      );
      final dark = buildThemeData(
        const ThemeConfig(),
        brightness: Brightness.dark,
      );
      expect(light.textTheme.bodyMedium?.color, const Color(0xFF000000));
      expect(dark.textTheme.bodyMedium?.color, const Color(0xFFFFFFFF));
    });

    test('显式 textColor 优先于自动值', () {
      final t = buildThemeData(
        const ThemeConfig(textColor: '#123456'),
        brightness: Brightness.dark,
      );
      expect(t.textTheme.bodyMedium?.color, const Color(0xFF123456));
    });

    test('显式 textColor 非法时回退到该深浅色下的可读色', () {
      final dark = buildThemeData(
        const ThemeConfig(textColor: 'not-a-color'),
        brightness: Brightness.dark,
      );
      // 深色模式下应回退到白色（而不是黑，否则看不见）
      expect(dark.textTheme.bodyMedium?.color, const Color(0xFFFFFFFF));
    });
  });

  group('buildThemeData：色板与强调色', () {
    test('brightness 正确传给 ColorScheme', () {
      expect(
        buildThemeData(const ThemeConfig(), brightness: Brightness.dark)
            .colorScheme
            .brightness,
        Brightness.dark,
      );
      expect(
        buildThemeData(const ThemeConfig(), brightness: Brightness.light)
            .colorScheme
            .brightness,
        Brightness.light,
      );
    });

    test('强调色影响色板（不同 seed 得到不同 primary）', () {
      final a = buildThemeData(
        const ThemeConfig(accentColor: '#4A90D9'),
        brightness: Brightness.light,
      );
      final b = buildThemeData(
        const ThemeConfig(accentColor: '#C62828'),
        brightness: Brightness.light,
      );
      expect(a.colorScheme.primary, isNot(b.colorScheme.primary));
    });

    test('使用 Material 3', () {
      expect(
        buildThemeData(const ThemeConfig(), brightness: Brightness.light)
            .useMaterial3,
        isTrue,
      );
    });
  });

  // ── 标题栏闪烁（用户实测反馈）──────────────────────────────────────
  //
  // 现象：纯色背景下标题栏会「奇怪地闪烁」。
  // 根因：M3 的 AppBar 默认 scrolledUnderElevation = 3.0，且未显式指定的
  // surfaceTintColor 会回落成 colorScheme.surfaceTint；内容滚动到标题栏下方时
  // 该色调叠加层会做透明度动画。由于本应用的 AppBar 底色是透明的
  //（为了让全屏背景透出来），这层动画就表现为标题栏忽明忽暗。
  group('buildThemeData：标题栏不闪烁', () {
    test('禁用 scrolledUnderElevation（滚动时不做高程变化）', () {
      for (final b in [Brightness.light, Brightness.dark]) {
        final t = buildThemeData(const ThemeConfig(), brightness: b);
        expect(t.appBarTheme.scrolledUnderElevation, 0,
            reason: 'M3 默认 3.0，会让 AppBar 在滚动到内容下方时叠色');
      }
    });

    test('禁用 surfaceTintColor（不叠加色调层）', () {
      for (final b in [Brightness.light, Brightness.dark]) {
        final t = buildThemeData(const ThemeConfig(), brightness: b);
        expect(t.appBarTheme.surfaceTintColor, Colors.transparent,
            reason: '未显式设置时会回落成 surfaceTint，导致滚动时色调动画');
      }
    });

    test('禁用阴影色，且高程为 0', () {
      final t = buildThemeData(const ThemeConfig(), brightness: Brightness.light);
      expect(t.appBarTheme.shadowColor, Colors.transparent);
      expect(t.appBarTheme.elevation, 0);
    });

    test('AppBar 底色透明（让全屏背景层透出来）', () {
      final t = buildThemeData(const ThemeConfig(), brightness: Brightness.light);
      expect(t.appBarTheme.backgroundColor, Colors.transparent);
    });

    // 状态栏图标配色必须显式给出：AppBar 在未指定时会用
    // estimateBrightnessForColor(底色) 推断，而底色是 transparent 时
    // 推断结果恒为"浅色"，导致深色主题下图标与背景不匹配。
    test('状态栏样式随深浅色显式指定（不靠 transparent 推断）', () {
      final light = buildThemeData(const ThemeConfig(), brightness: Brightness.light);
      final dark = buildThemeData(const ThemeConfig(), brightness: Brightness.dark);

      expect(light.appBarTheme.systemOverlayStyle, SystemUiOverlayStyle.dark,
          reason: '浅色底应配深色状态栏图标');
      expect(dark.appBarTheme.systemOverlayStyle, SystemUiOverlayStyle.light,
          reason: '深色底应配浅色状态栏图标');
      expect(light.appBarTheme.systemOverlayStyle,
          isNot(dark.appBarTheme.systemOverlayStyle),
          reason: '两种主题必须给出不同值，否则说明仍在依赖透明色推断');
    });
  });
}
