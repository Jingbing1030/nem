import 'dart:convert';

/// 深浅色模式的三个取值。
///
/// 用字符串常量而非 enum，是为了与既有 JSON 格式（本来就存字符串）兼容，
/// 且避免 `ThemeConfig` 的 const 构造器对 enum 的额外依赖。
class BrightnessMode {
  const BrightnessMode._();

  /// 跟随系统（默认）。
  static const String system = 'system';
  static const String light = 'light';
  static const String dark = 'dark';

  /// 全部合法取值，供 UI 遍历。
  static const List<String> all = <String>[system, light, dark];

  /// 展示名。
  static String label(String mode) => switch (mode) {
        light => '浅色',
        dark => '深色',
        _ => '跟随系统',
      };
}

/// 主题配置。序列化后存 shared_preferences。
class ThemeConfig {
  const ThemeConfig({
    this.backgroundImage,
    this.backgroundOpacity = 0.15,
    this.textColor,
    this.accentColor = '#4A90D9',
    this.brightness = BrightnessMode.system,
  });

  /// 背景图片相对路径（相对笔记库根目录，如 `theme/background.jpg`）。
  ///
  /// **不放在 assets/images/ 下** —— 那里会被 GC 与同步波及（需求第 8 节第 5 条）。
  final String? backgroundImage;

  /// 背景不透明度，0~1，默认 0.15。
  final double backgroundOpacity;

  /// 文字颜色，`#RRGGBB`；**为 null 表示「自动」**——
  /// 按当前深浅色选用黑或白。
  ///
  /// ⚠️ 早期版本默认 `'#000000'`，这在深色模式下会导致**黑字黑底看不见**
  /// （深色主题的 fallback 永远不会生效，因为 `#000000` 能成功解析）。
  /// 改为 null 后由 `buildThemeData` 按 brightness 决定。
  final String? textColor;

  /// 强调色，`#RRGGBB`。
  final String accentColor;

  /// 深浅色模式：`system`（跟随系统）/ `light` / `dark`。
  ///
  /// 默认 `system` —— 用户打开 App 就该得到与系统一致的观感，
  /// 而不是被强制成浅色（那是早期版本的默认值）。
  final String brightness;

  /// 是否明确要求深色（不含 `system`；system 需运行时解析）。
  bool get isDark => brightness == BrightnessMode.dark;

  /// 是否跟随系统。
  bool get followsSystem => brightness == BrightnessMode.system;

  ThemeConfig copyWith({
    String? backgroundImage,
    double? backgroundOpacity,
    String? textColor,
    String? accentColor,
    String? brightness,
    bool clearBackground = false,
    /// 把 textColor 显式设回「自动」。
    /// （`copyWith(textColor: null)` 无法表达这个意图 —— null 表示"不改"。）
    bool clearTextColor = false,
  }) =>
      ThemeConfig(
        backgroundImage:
            clearBackground ? null : (backgroundImage ?? this.backgroundImage),
        backgroundOpacity: backgroundOpacity ?? this.backgroundOpacity,
        textColor: clearTextColor ? null : (textColor ?? this.textColor),
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
        textColor: json['textColor'] as String?,
        accentColor: (json['accentColor'] as String?) ?? '#4A90D9',
        // 旧版本没有 brightness 字段或只存 light/dark；缺省时按跟随系统处理。
        brightness: (json['brightness'] as String?) ?? BrightnessMode.system,
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
