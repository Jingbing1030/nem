import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

/// 防重放：缓存最近收到的 nonce，重复即判定为重放。
///
/// 需求文档规定缓存最近 200 个 nonce。
class NonceCache {
  NonceCache({this.capacity = 200});

  /// 缓存容量。
  final int capacity;

  final LinkedHashSet<String> _seen = LinkedHashSet<String>();

  /// 检查并登记 nonce。返回 true 表示首次出现（可接受），
  /// false 表示重复（应丢弃该消息）。
  bool checkAndStore(List<int> nonce) {
    final key = base64.encode(nonce);
    if (_seen.contains(key)) return false;
    _seen.add(key);
    // 超出容量时淘汰最旧的。
    while (_seen.length > capacity) {
      _seen.remove(_seen.first);
    }
    return true;
  }

  /// 当前缓存条目数。
  int get length => _seen.length;

  /// 清空（连接重建时调用）。
  void clear() => _seen.clear();

  /// 是否已见过该 nonce。
  bool contains(Uint8List nonce) => _seen.contains(base64.encode(nonce));
}

/// 带过期时间的 nonce 缓存（变更 5：配对请求的 nonce 缓存 60s）。
///
/// 与 [NonceCache]（按条数滑动窗口）不同，本类按**时间**过期，
/// 语义更贴近「60 秒内同一 nonce 只接受一次」。
class TtlNonceCache {
  TtlNonceCache({this.ttl = const Duration(seconds: 60), this.maxEntries = 4096});

  /// 条目存活时长。
  final Duration ttl;

  /// 上限，防止恶意流量把内存撑爆。
  final int maxEntries;

  final Map<String, DateTime> _seen = <String, DateTime>{};

  /// 检查并登记。返回 true 表示首次出现（可接受）。
  bool checkAndStore(List<int> nonce, {DateTime? now}) {
    final t = now ?? DateTime.now();
    _evict(t);
    final key = base64.encode(nonce);
    final prev = _seen[key];
    if (prev != null && t.difference(prev) < ttl) return false;
    _seen[key] = t;
    return true;
  }

  bool contains(List<int> nonce, {DateTime? now}) {
    _evict(now ?? DateTime.now());
    return _seen.containsKey(base64.encode(nonce));
  }

  int get length => _seen.length;

  void clear() => _seen.clear();

  void _evict(DateTime now) {
    _seen.removeWhere((_, t) => now.difference(t) >= ttl);
    if (_seen.length > maxEntries) {
      // 超限时丢掉最旧的一半（简单且够用）。
      final sorted = _seen.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      for (final e in sorted.take(sorted.length - maxEntries ~/ 2)) {
        _seen.remove(e.key);
      }
    }
  }
}
