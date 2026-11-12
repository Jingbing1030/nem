import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'app_config.dart';

/// 配置与密钥的持久化。
///
/// **分工严格**：
/// - shared_preferences：主题、设备名等**非敏感**配置
/// - flutter_secure_storage：masterKey（**唯一**存放位置）
class ConfigStore {
  ConfigStore(this._prefs, this._secure);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  static const String _configKey = 'app_config_v1';
  static const String _masterKeyKey = 'notepad_master_key_v1';

  static Future<ConfigStore> open() async {
    final prefs = await SharedPreferences.getInstance();
    const secure = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    return ConfigStore(prefs, secure);
  }

  /// 读取配置；不存在的字段用默认值补齐（首次启动即初始化）。
  Future<AppConfig> load() async {
    final raw = _prefs.getString(_configKey);
    final hasKey = await hasMasterKey();

    if (raw == null) {
      final fresh = AppConfig(
        deviceId: const Uuid().v4(),
        deviceName: '未命名设备',
        theme: const ThemeConfig(),
        hasMasterKey: hasKey,
      );
      await save(fresh);
      return fresh;
    }
    final cfg = AppConfig.decode(raw);
    // 以 secure_storage 的实际情况为准（唯一真相源）。
    return cfg.copyWith(hasMasterKey: hasKey);
  }

  Future<void> save(AppConfig cfg) async {
    await _prefs.setString(_configKey, cfg.encode());
  }

  /// 是否已持有 masterKey。
  Future<bool> hasMasterKey() async =>
      (await _secure.read(key: _masterKeyKey)) != null;

  /// 读取 masterKey。**只在需要派生会话密钥时调用。**
  Future<String?> readMasterKey() => _secure.read(key: _masterKeyKey);

  /// 写入 masterKey（配对成功时）。
  Future<void> writeMasterKey(String masterKey) =>
      _secure.write(key: _masterKeyKey, value: masterKey);

  /// 清除 masterKey（重置配对时）。
  Future<void> clearMasterKey() => _secure.delete(key: _masterKeyKey);

  /// 原始 shared_preferences 内容（自检用：确认里面没有明文密钥）。
  Map<String, Object?> debugDumpPrefs() => _prefs.getKeys().fold(
        <String, Object?>{},
        (acc, k) => acc..[k] = _prefs.get(k),
      );
}
