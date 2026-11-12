import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/config/app_config.dart';

void main() {
  group('ThemeConfig', () {
    test('默认值符合需求（透明度 0.15）', () {
      const t = ThemeConfig();
      expect(t.backgroundOpacity, 0.15);
      expect(t.textColor, '#000000');
      expect(t.accentColor, '#4A90D9');
      expect(t.backgroundImage, isNull);
      expect(t.isDark, isFalse);
    });

    test('JSON 往返无损', () {
      const t = ThemeConfig(
        backgroundImage: 'theme/background.jpg',
        backgroundOpacity: 0.42,
        textColor: '#123456',
        accentColor: '#ABCDEF',
        brightness: 'dark',
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
      expect(t.textColor, '#000000');
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
