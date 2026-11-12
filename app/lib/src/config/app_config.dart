import 'dart:convert';

/// 主题配置。序列化后存 shared_preferences。
class ThemeConfig {
  const ThemeConfig({
    this.backgroundImage,
    this.backgroundOpacity = 0.15,
    this.textColor = '#000000',
    this.accentColor = '#4A90D9',
    this.brightness = 'light',
  });

  /// 背景图片相对路径（相对笔记库根目录，如 `theme/background.jpg`）。
  ///
  /// **不放在 assets/images/ 下** —— 那里会被 GC 与同步波及（需求第 8 节第 5 条）。
  final String? backgroundImage;

  /// 背景不透明度，0~1，默认 0.15。
  final double backgroundOpacity;

  /// 文字颜色，`#RRGGBB`。
  final String textColor;

  /// 强调色，`#RRGGBB`。
  final String accentColor;

  /// `light` / `dark`。
  final String brightness;

  bool get isDark => brightness == 'dark';

  ThemeConfig copyWith({
    String? backgroundImage,
    double? backgroundOpacity,
    String? textColor,
    String? accentColor,
    String? brightness,
    bool clearBackground = false,
  }) =>
      ThemeConfig(
        backgroundImage:
            clearBackground ? null : (backgroundImage ?? this.backgroundImage),
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        textColor: textColor ?? this.textColor,
        accentColor: accentColor ?? this.accentColor,
        brightness: brightness ?? this.brightness,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'backgroundImage': backgroundImage,
        'backgroundOpacity': backgroundOpacity,
        'textColor': textColor,
        'accentColor': accentColor,
        'brightness': brightness,
      };

  static ThemeConfig fromJson(Map<String, dynamic> json) => ThemeConfig(
        backgroundImage: json['backgroundImage'] as String?,
        backgroundOpacity:
            (json['backgroundOpacity'] as num?)?.toDouble() ?? 0.15,
        textColor: (json['textColor'] as String?) ?? '#000000',
        accentColor: (json['accentColor'] as String?) ?? '#4A90D9',
        brightness: (json['brightness'] as String?) ?? 'light',
      );
}

/// 应用配置。存 shared_preferences（**不含 masterKey**）。
///
/// masterKey 存 flutter_secure_storage，这里只在 JSON 里保留一个布尔标记，
/// 用于判断「本机是否已生成密钥」（对应 mDNS TXT 的 hasKey）。
class AppConfig {
  const AppConfig({
    required this.deviceId,
    required this.deviceName,
    required this.theme,
    this.syncEnabled = true,
    this.hasMasterKey = false,
  });

  /// 设备 UUID，安装时生成。
  final String deviceId;

  /// 用户可编辑的设备名。
  final String deviceName;

  final ThemeConfig theme;

  final bool syncEnabled;

  /// 是否已持有 masterKey —— **注意：这里只存标记，不存密钥本身**。
  final bool hasMasterKey;

  AppConfig copyWith({
    String? deviceName,
    ThemeConfig? theme,
    bool? syncEnabled,
    bool? hasMasterKey,
  }) =>
      AppConfig(
        deviceId: deviceId,
        deviceName: deviceName ?? this.deviceName,
        theme: theme ?? this.theme,
        syncEnabled: syncEnabled ?? this.syncEnabled,
        hasMasterKey: hasMasterKey ?? this.hasMasterKey,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'deviceId': deviceId,
        'deviceName': deviceName,
        'theme': theme.toJson(),
        'syncEnabled': syncEnabled,
        'hasMasterKey': hasMasterKey,
      };

  static AppConfig fromJson(Map<String, dynamic> json) => AppConfig(
        deviceId: json['deviceId'] as String,
        deviceName: (json['deviceName'] as String?) ?? '未命名设备',
        theme: ThemeConfig.fromJson(
          (json['theme'] as Map?)?.cast<String, dynamic>() ??
              <String, dynamic>{},
        ),
        syncEnabled: (json['syncEnabled'] as bool?) ?? true,
        hasMasterKey: (json['hasMasterKey'] as bool?) ?? false,
      );

  String encode() => jsonEncode(toJson());

  static AppConfig decode(String raw) =>
      fromJson(jsonDecode(raw) as Map<String, dynamic>);
}
