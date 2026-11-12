import 'dart:convert';

import 'package:http/http.dart' as http;

import '../log.dart';
import 'release_info.dart';

/// 查询 GitHub 最新 Release 的客户端。
///
/// **三条硬性约束**（对应的设计决策）：
/// 1. **公开仓库，不携带任何 token** —— 客户端里硬编码凭据等于泄漏；
/// 2. **未认证请求限流 60 次/小时/IP**，因此即使没有新版本也要把结果缓存
///    [ttl]（默认 6 小时），避免每次冷启动都打一次 API；
/// 3. **失败必须静默** —— 网络不可用 / 403 限流 / 超时 / JSON 结构变化，
///    一律返回 null 并把原因写进 debug 日志（`Log` 仅在 debug 生效），
///    绝不抛给调用方，更不阻塞启动。
class UpdateChecker {
  UpdateChecker({
    http.Client? client,
    this.owner = 'Jingbing1030',
    this.repo = 'nem',
    this.timeout = const Duration(seconds: 6),
    this.ttl = const Duration(hours: 6),
    this.failureTtl = const Duration(minutes: 30),
    DateTime Function()? now,
  })  : _client = client ?? http.Client(),
        _now = now ?? DateTime.now;

  final http.Client _client;

  /// 仓库属主。
  final String owner;

  /// 仓库名。
  final String repo;

  /// 单次请求超时。**不宜过大** —— 这是首屏之后的附属功能。
  final Duration timeout;

  /// 成功结果的缓存时长（未认证限流 60 次/小时，缓存是必需的礼貌）。
  final Duration ttl;

  /// 失败结果的缓存时长 —— 离线/限流时短期内不再重试。
  final Duration failureTtl;

  final DateTime Function() _now;

  final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  /// API 地址。
  Uri get apiUri => Uri.parse(
        'https://api.github.com/repos/$owner/$repo/releases/latest',
      );

  /// 拉取最新 Release；**任何失败都返回 null，不抛异常**。
  ///
  /// [force] 为 true 时忽略缓存（用于「检查更新」的手动入口）。
  Future<ReleaseInfo?> fetchLatest({bool force = false}) async {
    final key = apiUri.toString();
    final cached = _cache[key];
    if (!force && cached != null) {
      final age = _now().difference(cached.at);
      // 时钟回拨（age < 0）时当作过期，重新请求。
      if (age >= Duration.zero) {
        final window = cached.info == null ? failureTtl : ttl;
        if (age < window) return cached.info;
      }
    }

    ReleaseInfo? info;
    try {
      final resp = await _client.get(
        apiUri,
        headers: const <String, String>{
          // 无 token：60/h 的匿名配额够用（有 6 小时缓存兜底）。
          'Accept': 'application/vnd.github+json',
          'X-GitHub-Api-Version': '2022-11-28',
          'User-Agent': 'lan-notepad-update-checker',
        },
      ).timeout(timeout);

      if (resp.statusCode == 200) {
        info = ReleaseInfo.fromJson(jsonDecode(resp.body));
        if (info == null) {
          Log.debug('更新检测：Release JSON 结构无法解析');
        }
      } else if (resp.statusCode == 403 || resp.statusCode == 429) {
        // 限流：读 X-RateLimit-Reset 只为日志，不做重试排队。
        Log.debug(
          '更新检测：GitHub API 限流（HTTP ${resp.statusCode}，'
          'reset=${resp.headers['x-ratelimit-reset']}）',
        );
      } else if (resp.statusCode == 404) {
        // 仓库还没有任何 Release —— 属于正常状态。
        Log.debug('更新检测：该仓库暂无 Release（HTTP 404）');
      } else {
        Log.debug('更新检测：HTTP ${resp.statusCode}');
      }
    } catch (e) {
      // SocketException / TimeoutException / FormatException 全在这里被吞掉。
      Log.debug('更新检测失败（已忽略）：$e');
      info = null;
    }

    _cache[key] = _CacheEntry(info, _now());
    return info;
  }

  /// 释放底层连接。
  void dispose() => _client.close();
}

class _CacheEntry {
  const _CacheEntry(this.info, this.at);

  final ReleaseInfo? info;
  final DateTime at;
}
