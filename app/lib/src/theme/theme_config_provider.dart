import 'package:flutter/material.dart';
// SystemUiOverlayStyle 定义在 services 里（material 不再导出它）。
import 'package:flutter/services.dart';

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
    // 透明，让 BackgroundScaffold 铺设的背景透出来（它**一定会**铺一层，
    // 且那层是全覆盖的 —— 包括 AppBar 与状态栏区域，见该文件顶部说明）。
    scaffoldBackgroundColor: Colors.transparent,
    // canvasColor 保持默认（= scheme.surface）：它会影响 Drawer / 弹出菜单 /
    // BottomSheet 等组件的默认底色。曾经把它也设为透明，导致这些浮层透出下层
    // 内容，属于自找麻烦 —— 只有 Scaffold 需要透明。
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: text,
      // ── 以下三项用于消除「标题栏奇怪闪烁」──────────────────────────
      //
      // 机制：M3 的 AppBar 默认 scrolledUnderElevation = 3.0，且其
      // surfaceTintColor 在未显式指定时会回落成 colorScheme.surfaceTint
      // （一个带强调色的半透明色）。当列表内容滚动到标题栏下方时，
      // AppBar 会把「surfaceTint 叠加层」的透明度做**动画过渡**。
      // 本应用的 AppBar 底色是透明的（为了让背景层透出来），
      // 于是这层动画直接表现为标题栏整体颜色的忽明忽暗 —— 即用户看到的"闪烁"。
      //
      // 三项一起设才彻底：scrolledUnderElevation=0 去掉高程变化，
      // surfaceTintColor=transparent 去掉色调叠加，
      // shadowColor=transparent 去掉可能的阴影突变。
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      // 状态栏图标配色必须**显式**给出。
      //
      // 机制：AppBar 未指定本项时，会用
      // `ThemeData.estimateBrightnessForColor(背景色)` 推断。
      // 本应用的 AppBar 底色是 transparent —— 透明色的亮度估算结果是"浅色"，
      // 于是无论深色还是浅色主题，状态栏图标都被当成深色背景来处理
      // （即使用浅色图标）。深色主题下这就表现为状态栏图标忽明忽暗、
      // 与背景层不匹配。这里按主题深浅直接给出正确值。
      systemOverlayStyle: isDark
          ? SystemUiOverlayStyle.light   // 深色底 → 浅色图标
          : SystemUiOverlayStyle.dark,   // 浅色底 → 深色图标
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
