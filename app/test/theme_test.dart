import 'package:flutter/material.dart';
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
    // 底色始终透明，由 BackgroundScaffold 负责铺一层不透明内容
    // （用户背景 → 内置背景 → 纯色）。纯黑问题的修复是靠「总有一层铺底」，
    // 而不是靠这里的底色 —— 见 background_scaffold.dart。
    test('底色始终透明（背景由 BackgroundScaffold 铺设）', () {
      for (final b in [Brightness.light, Brightness.dark]) {
        final t = buildThemeData(const ThemeConfig(), brightness: b);
        expect(t.scaffoldBackgroundColor, Colors.transparent);
        expect(t.canvasColor, Colors.transparent);
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

    test('内置背景资源路径已声明', () {
      // 该常量由 background_scaffold.dart 提供，assets 在 pubspec 中注册。
      expect(kBundledBackground, 'assets/backgrounds/app_bg.jpg');
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
}
