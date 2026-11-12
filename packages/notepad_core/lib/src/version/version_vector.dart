import 'dart:convert';

/// 版本向量：`deviceId -> 计数`（变更 6.1）。
///
/// 替代第一版的单一 `version: int` 与 updatedAt LWW 判定。
class VersionVector {
  VersionVector([Map<String, int>? counters])
      : _counters = Map<String, int>.from(counters ?? const <String, int>{});

  final Map<String, int> _counters;

  /// 只读视图。
  Map<String, int> get counters => Map<String, int>.unmodifiable(_counters);

  /// 空向量。
  static VersionVector empty() => VersionVector();

  /// 该设备当前的计数（缺席视为 0）。
  int operator [](String deviceId) => _counters[deviceId] ?? 0;

  /// 自增某设备的计数，返回新向量（不可变风格，避免共享可变状态）。
  VersionVector increment(String deviceId) {
    final next = Map<String, int>.from(_counters);
    next[deviceId] = (next[deviceId] ?? 0) + 1;
    return VersionVector(next);
  }

  /// 取两个向量的逐项最大值（并发编辑合并时用）。
  VersionVector merge(VersionVector other) {
    final next = Map<String, int>.from(_counters);
    for (final e in other._counters.entries) {
      final cur = next[e.key] ?? 0;
      if (e.value > cur) next[e.key] = e.value;
    }
    return VersionVector(next);
  }

  /// 参与的设备 id 集合。
  Set<String> get deviceIds => _counters.keys.toSet();

  bool get isEmpty => _counters.values.every((v) => v == 0);

  // ---------------------------------------------------------------- 比较

  /// 判断与 [other] 的关系（变更 6.1）。
  ///
  /// - [VersionRelation.equal]：完全相同
  /// - [VersionRelation.dominates]：本向量支配对方（对方的所有计数 ≤ 本方向量，且至少一项 <）
  /// - [VersionRelation.dominated]：被对方支配
  /// - [VersionRelation.concurrent]：互不支配（并发编辑 → 需要冲突副本）
  VersionRelation compare(VersionVector other) {
    var allLe = true; // this <= other 对所有设备成立
    var allGe = true; // this >= other 对所有设备成立

    final ids = <String>{..._counters.keys, ...other._counters.keys};
    for (final id in ids) {
      final a = this[id];
      final b = other[id];
      if (a > b) allLe = false;
      if (a < b) allGe = false;
      if (!allLe && !allGe) return VersionRelation.concurrent;
    }

    if (allLe && allGe) return VersionRelation.equal;
    if (allLe) return VersionRelation.dominated; // this <= other
    return VersionRelation.dominates; // this >= other
  }

  bool dominates(VersionVector other) =>
      compare(other) == VersionRelation.dominates;

  bool isConcurrentWith(VersionVector other) =>
      compare(other) == VersionRelation.concurrent;

  /// 对方是否「没动过」：以 [baseline] 为共同基线时，
  /// 对方的向量仍等于基线的部分（用于判断能否安全发 patch）。
  bool peerUnchangedSince(VersionVector baseline) =>
      compare(baseline) == VersionRelation.equal;

  // ---------------------------------------------------------------- 序列化

  /// 序列化为 JSON 字符串（数据库存 TEXT）。
  String encode() => jsonEncode(_counters);

  /// 从 JSON 字符串还原。非法输入返回空向量。
  static VersionVector decode(String raw) {
    try {
      final m = jsonDecode(raw);
      if (m is! Map) return VersionVector();
      return VersionVector(<String, int>{
        for (final e in m.entries)
          e.key.toString(): (e.value is int) ? e.value as int : int.tryParse('${e.value}') ?? 0,
      });
    } catch (_) {
      return VersionVector();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is VersionVector &&
      other._counters.length == _counters.length &&
      _counters.entries.every((e) => other._counters[e.key] == e.value);

  @override
  int get hashCode => Object.hashAllUnordered(
        _counters.entries.map((e) => Object.hash(e.key, e.value)),
      );

  @override
  String toString() => 'VV($_counters)';
}

/// 版本向量的偏序关系。
enum VersionRelation { equal, dominates, dominated, concurrent }
