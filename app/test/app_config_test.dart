import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/config/app_config.dart';

void main() {
  group('ThemeConfig', () {
    test('默认值：透明度 0.15、文字色自动、跟随系统', () {
      const t = ThemeConfig();
      expect(t.backgroundOpacity, 0.15);
      // textColor 默认 null = 自动（按深浅色选黑/白）。
      // 早期默认 '#000000' 会让深色模式黑字黑底看不见，故改为可空。
      expect(t.textColor, isNull);
      expect(t.accentColor, '#4A90D9');
      expect(t.backgroundImage, isNull);
      // 默认跟随系统，而不是强制浅色。
      expect(t.followsSystem, isTrue);
      expect(t.isDark, isFalse); // system 不等于"明确深色"
      expect(t.brightness, BrightnessMode.system);
    });

    test('BrightnessMode 三个取值与展示名', () {
      expect(BrightnessMode.all, hasLength(3));
      expect(BrightnessMode.label(BrightnessMode.system), '跟随系统');
      expect(BrightnessMode.label(BrightnessMode.light), '浅色');
      expect(BrightnessMode.label(BrightnessMode.dark), '深色');
      // 未知取值不应崩溃，按"跟随系统"处理
      expect(BrightnessMode.label('nonsense'), '跟随系统');
    });

    test('isDark / followsSystem 三者互斥', () {
      expect(const ThemeConfig(brightness: BrightnessMode.light).isDark, isFalse);
      expect(const ThemeConfig(brightness: BrightnessMode.light).followsSystem, isFalse);
      expect(const ThemeConfig(brightness: BrightnessMode.dark).isDark, isTrue);
      expect(const ThemeConfig(brightness: BrightnessMode.dark).followsSystem, isFalse);
      expect(const ThemeConfig(brightness: BrightnessMode.system).isDark, isFalse);
      expect(const ThemeConfig(brightness: BrightnessMode.system).followsSystem, isTrue);
    });

    test('copyWith 可把文字颜色设回自动（clearTextColor）', () {
      const t = ThemeConfig(textColor: '#123456');
      // 注意：copyWith(textColor: null) 表示"不改"，不是"清空"
      expect(t.copyWith().textColor, '#123456');
      expect(t.copyWith(textColor: '#ABCDEF').textColor, '#ABCDEF');
      expect(t.copyWith(clearTextColor: true).textColor, isNull);
    });

    test('copyWith 可切换 brightness', () {
      const t = ThemeConfig();
      expect(
        t.copyWith(brightness: BrightnessMode.dark).brightness,
        BrightnessMode.dark,
      );
      expect(
        t.copyWith(brightness: BrightnessMode.light).brightness,
        BrightnessMode.light,
      );
    });

    test('JSON 往返无损', () {
      const t = ThemeConfig(
        backgroundImage: 'theme/background.jpg',
        backgroundOpacity: 0.42,
        textColor: '#123456',
        accentColor: '#ABCDEF',
        brightness: BrightnessMode.dark,
      );
      final back = ThemeConfig.fromJson(
        jsonDecode(jsonEncode(t.toJson())) as Map<String, dynamic>,
      );
      expect(back.backgroundImage, t.backgroundImage);
      expect(back.backgroundOpacity, closeTo(0.42, 1e-9));
      expect(back.textColor, t.textColor);
      expect(back.accentColor, t.accentColor);
      expect(back.isDark, isTrue);
    });

    test('copyWith 可清除背景图', () {
      const t = ThemeConfig(backgroundImage: 'theme/a.jpg');
      expect(t.copyWith(clearBackground: true).backgroundImage, isNull);
      expect(t.copyWith(backgroundImage: 'theme/b.jpg').backgroundImage,
          'theme/b.jpg');
      expect(t.copyWith().backgroundImage, 'theme/a.jpg');
    });

    test('字段缺失时用默认值兜底（向前兼容）', () {
      final t = ThemeConfig.fromJson(<String, dynamic>{});
      expect(t.backgroundOpacity, 0.15);
      expect(t.textColor, isNull); // 自动
      expect(t.brightness, BrightnessMode.system);
    });

    test('旧版本配置（无 brightness / 有 textColor）仍可解析', () {
      // 模拟早期版本写下的 JSON：brightness 缺失、textColor 是具体色值
      final t = ThemeConfig.fromJson(<String, dynamic>{
        'backgroundImage': 'theme/old.jpg',
        'textColor': '#000000',
      });
      expect(t.backgroundImage, 'theme/old.jpg');
      // 已存的显式颜色要保留（不回退成自动）
      expect(t.textColor, '#000000');
      // 缺 brightness 时按跟随系统，而不是沿用旧的"强制浅色"
      expect(t.brightness, BrightnessMode.system);
    });
  });

  group('AppConfig', () {
    const cfg = AppConfig(
      deviceId: 'dev-1',
      deviceName: '我的手机',
      theme: ThemeConfig(),
    );

    test('JSON 往返无损', () {
      final back = AppConfig.decode(cfg.encode());
      expect(back.deviceId, 'dev-1');
      expect(back.deviceName, '我的手机');
      expect(back.syncEnabled, isTrue);
      expect(back.hasMasterKey, isFalse);
    });

    test('copyWith 保留 deviceId（设备身份不可变）', () {
      final updated = cfg.copyWith(deviceName: '新名字');
      expect(updated.deviceId, cfg.deviceId);
      expect(updated.deviceName, '新名字');
    });

    test('序列化结果里不含任何密钥字段（安全要求）', () {
      final raw = cfg.encode().toLowerCase();
      // 只允许出现 hasMasterKey 这个「是否有密钥」的标记
      expect(raw.contains('masterkey'), isTrue); // 即 hasMasterKey
      expect(raw.contains('"masterkey"'), isFalse);
      expect(raw.contains('secret'), isFalse);
      expect(raw.contains('password'), isFalse);
      expect(raw.contains('token'), isFalse);
    });

    test('hasMasterKey 只是布尔标记', () {
      final json = cfg.toJson();
      expect(json['hasMasterKey'], isA<bool>());
    });
  });
}
