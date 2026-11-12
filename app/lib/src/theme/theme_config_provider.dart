import 'package:flutter/material.dart';

import '../config/app_config.dart';

/// 把 `#RRGGBB` 解析为 [Color]。
Color parseHexColor(String hex, {Color fallback = Colors.black}) {
  var h = hex.trim();
  if (h.startsWith('#')) h = h.substring(1);
  if (h.length == 6) h = 'FF$h';
  if (h.length != 8) return fallback;
  final v = int.tryParse(h, radix: 16);
  return v == null ? fallback : Color(v);
}

/// 由主题配置构造 [ThemeData]。
ThemeData buildThemeData(ThemeConfig cfg) {
  final accent = parseHexColor(cfg.accentColor, fallback: const Color(0xFF4A90D9));
  final text = parseHexColor(
    cfg.textColor,
    fallback: cfg.isDark ? Colors.white : Colors.black,
  );

  final scheme = ColorScheme.fromSeed(
    seedColor: accent,
    brightness: cfg.isDark ? Brightness.dark : Brightness.light,
  );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    // 背景图铺底时，页面底色必须透明，否则会盖住背景（见 BackgroundScaffold）。
    scaffoldBackgroundColor: Colors.transparent,
    canvasColor: Colors.transparent,
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      foregroundColor: text,
    ),
    textTheme: _applyTextColor(
      (cfg.isDark ? ThemeData.dark() : ThemeData.light()).textTheme,
      text,
    ),
  );
}

TextTheme _applyTextColor(TextTheme base, Color color) => base.apply(
      bodyColor: color,
      displayColor: color,
    );
