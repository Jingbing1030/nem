import 'dart:io';

/// 配对失败限流：同一 IP 60 秒内失败 3 次 → 锁定 60 秒。
///
/// 需求 5.5 / 4.2：失败 3 次锁 60s，期间一律拒绝。
class PairingGuard {
  PairingGuard({
    this.failureLimit = 3,
    this.window = const Duration(seconds: 60),
    this.lockout = const Duration(seconds: 60),
  });

  /// 失败次数上限。
  final int failureLimit;

  /// 统计窗口。
  final Duration window;

  /// 锁定时长。
  final Duration lockout;

  final Map<String, List<DateTime>> _failures = <String, List<DateTime>>{};
  final Map<String, DateTime> _lockedUntil = <String, DateTime>{};

  /// 该 IP 当前是否被锁定。
  bool isLocked(String ip, {DateTime? now}) {
    final until = _lockedUntil[ip];
    if (until == null) return false;
    final t = now ?? DateTime.now();
    if (t.isAfter(until)) {
      _lockedUntil.remove(ip);
      _failures.remove(ip);
      return false;
    }
    return true;
  }

  /// 剩余锁定秒数（未锁定返回 0）。
  int lockRemainingSeconds(String ip, {DateTime? now}) {
    if (!isLocked(ip, now: now)) return 0;
    final t = now ?? DateTime.now();
    return _lockedUntil[ip]!.difference(t).inSeconds + 1;
  }

  /// 记录一次失败；达到上限则锁定。
  void recordFailure(String ip, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final list = _failures.putIfAbsent(ip, () => <DateTime>[]);
    list.add(t);
    // 只保留窗口内的失败
    list.removeWhere((x) => t.difference(x) > window);
    if (list.length >= failureLimit) {
      _lockedUntil[ip] = t.add(lockout);
      list.clear();
    }
  }

  /// 配对成功后清除该 IP 的失败记录。
  void recordSuccess(String ip) {
    _failures.remove(ip);
    _lockedUntil.remove(ip);
  }

  /// 用于日志与测试：某 IP 的当前失败次数。
  int failureCount(String ip, {DateTime? now}) {
    final t = now ?? DateTime.now();
    final list = _failures[ip];
    if (list == null) return 0;
    list.removeWhere((x) => t.difference(x) > window);
    return list.length;
  }

  /// 从 socket 取对端 IP。
  static String ipOf(Socket socket) =>
      socket.remoteAddress.address.isEmpty ? 'unknown' : socket.remoteAddress.address;
}
