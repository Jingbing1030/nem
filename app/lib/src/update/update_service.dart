import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../log.dart';
import 'release_info.dart';
import 'update_checker.dart';
import 'version.dart';

/// 更新提示的业务决策：**「该不该弹、弹什么」全在这里**。
///
/// 这一层被刻意做成不依赖 Flutter / 不依赖网络实现（两者都从构造参数注入），
/// 因此可以在单测里用假 HTTP 响应 + 假 prefs 穷举验证：
/// - 版本比较（走 [isNewerVersion]）；
/// - 「跳过此版本」的持久化语义（同版本不再提示，更高版本仍提示）；
/// - 任何失败路径都返回 null。
// ignore_for_file: prefer_initializing_formals
// —— 私有字段（_prefs）配公开具名参数（prefs），分析器的这条建议不适用。
class UpdateService {
  UpdateService({
    required SharedPreferences prefs,
    UpdateChecker? checker,
    Future<String> Function()? currentVersionLoader,
  })  : _prefs = prefs,
        _checker = checker ?? UpdateChecker(),
        _loadCurrentVersion = currentVersionLoader ?? _defaultVersionLoader;

  /// 「跳过此版本」记录的 key（存归一化后的版本号）。
  static const String skippedVersionKey = 'update_skipped_version_v1';

  final SharedPreferences _prefs;
  final UpdateChecker _checker;
  final Future<String> Function() _loadCurrentVersion;

  /// 当前 App 版本（形如 `0.2.0`，build 号已去掉）。
  Future<String> currentVersion() async {
    final raw = await _loadCurrentVersion();
    return normalizeVersion(raw);
  }

  /// 用户跳过的版本号；未跳过为 null。
  String? skippedVersion() {
    final v = _prefs.getString(skippedVersionKey);
    return (v == null || v.isEmpty) ? null : v;
  }

  /// 记住「跳过此版本」。
  Future<void> skip(String version) =>
      _prefs.setString(skippedVersionKey, normalizeVersion(version));

  /// 清除跳过记录（设置页「不再跳过」之类的入口将来可用）。
  Future<void> clearSkip() => _prefs.remove(skippedVersionKey);

  /// 是否需要提示用户更新；不需要则返回 null。
  ///
  /// **任何一步失败都返回 null**（含读版本号失败、网络失败、JSON 异常）。
  Future<ReleaseInfo?> checkForUpdate({bool force = false}) async {
    try {
      final current = await currentVersion();
      final latest = await _checker.fetchLatest(force: force);
      if (latest == null) return null;

      final remote = normalizeVersion(latest.tagName);
      if (!isNewerVersion(current, remote)) {
        Log.debug('更新检测：已是最新（当前 $current，远端 $remote）');
        return null;
      }

      // 「跳过此版本」：同版本不再提示；更高版本仍然提示。
      final skipped = skippedVersion();
      if (skipped != null && compareVersions(remote, skipped) <= 0) {
        Log.debug('更新检测：$remote 已被用户跳过，不再提示');
        return null;
      }

      return latest;
    } catch (e) {
      Log.debug('更新检测决策失败（已忽略）：$e');
      return null;
    }
  }

  void dispose() => _checker.dispose();
  /// 真实实现：读平台包信息。
  ///
  /// `PackageInfo.fromPlatform()` 走 MethodChannel，在纯 Dart 单测里不可用，
  /// 所以这里被抽象成可注入的回调。
  static Future<String> _defaultVersionLoader() async {
    final info = await PackageInfo.fromPlatform();
    return info.version;
  }
}
