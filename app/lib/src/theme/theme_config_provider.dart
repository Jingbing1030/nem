import 'package:flutter/material.dart';

import '../config/app_config.dart';

/// 把 `#RRGGBB` 解析为 [Color]；无法解析时返回 [fallback]。
Color parseHexColor(String hex, {Color fallback = Colors.black}) {
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return fallback;
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(v);
}

/// 把 [BrightnessMode] 取值解析为实际使用的 [Brightness]。
///
/// `system` 时取 [platformBrightness]（即系统深色模式开关）；
/// 非法值按「跟随系统」处理，不让脏配置把界面搞坏。
Brightness resolveBrightness(String mode, Brightness platformBrightness) =>
    switch (mode) {
      BrightnessMode.light => Brightness.light,
      BrightnessMode.dark => Brightness.dark,
      _ => platformBrightness,
    };

/// 由主题配置构造 [ThemeData]。
///
/// [brightness] 是**已解析**的最终深浅色（调用方用 [resolveBrightness]
/// 把 `system` 解析成实际值），而不是配置里那个字符串 —— 这样本函数保持纯粹、
/// 便于单测，也不需要访问 `BuildContext`。
///
/// 底色**始终透明**：`BackgroundScaffold` 保证总有一层不透明内容铺底
/// （用户自选背景 → 内置背景 → 纯色），所以这里透明不会露出窗口底色。
///
/// ⚠️ 早期版本无条件透明，却**没有**任何组件负责铺底 —— 没设背景图时
/// 整棵 UI 全透明，直接露出 Android 窗口底色。深色模式下那是
/// `Theme.Black` 的 `colorBackground`（纯黑 #000000），而 M3 深色 surface 是
/// #111418，表现为「打开后突然变成纯黑」。修复分两部分：
/// 一是让本函数在无背景时给出不透明 surface（已由 BackgroundScaffold 接管），
/// 二是给 BackgroundScaffold 加内置背景兜底，从此底色可以安全地保持透明。
ThemeData buildThemeData(
  ThemeConfig cfg, {
  Brightness brightness = Brightness.light,
}) {
  final isDark = brightness == Brightness.dark;

  final accent = parseHexColor(cfg.accentColor, fallback: const Color(0xFF4A90D9));
  // textColor 为 null（默认）时按深浅色自动选黑/白。
  // 早期默认值 '#000000' 会让深色模式下的文字不可见 —— 这正是改成可空的原因。
  final text = cfg.textColor == null
      ? (isDark ? Colors.white : Colors.black)
      : parseHexColor(cfg.textColor!, fallback: isDark ? Colors.white : Colors.black);

  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: brightness,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    // 透明，让 BackgroundScaffold 铺设的背景透出来（它一定会铺一层）。
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: text,
    ),
    textTheme: _applyTextColor(
      (isDark ? ThemeData.dark() : ThemeData.light()).textTheme,
      text,
    ),
  );
}

TextTheme _applyTextColor(TextTheme base, Color color) => base.apply(
      bodyColor: color,
      displayColor: color,
    );
