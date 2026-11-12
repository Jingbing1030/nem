/// 语义化版本（SemVer）的解析与比较。
///
/// **只依赖 `dart:core`，不依赖 Flutter** —— 这样版本比较逻辑可以在纯 Dart
/// 单测里被穷举覆盖（`test/update_version_test.dart`）。
///
/// 支持的实际输入形态（来自 `pubspec.yaml` 与 GitHub Release 的 `tag_name`）：
/// - `0.2.0+1`  —— pubspec 的 `版本+build` 写法，build 段只用于构建，不参与比较；
/// - `v0.3.0`   —— GitHub 打 tag 的习惯带 `v` 前缀；
/// - `1.0`      —— 位数不等（按缺位补 0 处理，`1.0` == `1.0.0`）；
/// - `1.0.0-beta.2` —— 预发布版本，按 SemVer 规则**小于**同号正式版。
///
/// ⚠️ 明确不支持的：`1.0.0-rc1+build.5` 之后的进一步怪异写法、
/// 以及非数字的 release 段（如 `1.x`）—— 这类段一律按 0 处理，
/// 目的是**不抛异常、不因版本号脏数据阻断启动**。
library;

/// 解析结果：release 数字段 + 预发布标识段。
class ParsedVersion {
  const ParsedVersion({
    required this.release,
    required this.preRelease,
    required this.raw,
  });

  /// release 段，如 `1.2.3` → `[1, 2, 3]`。
  ///
  /// 比较时按需补 0，因此这里保留原始长度（`1.0` 与 `1.0.0` 长度不同但相等）。
  final List<int> release;

  /// 预发布标识段，如 `1.0.0-beta.2` → `['beta', '2']`；正式版为空列表。
  final List<String> preRelease;

  /// 原始输入（便于日志排查，不参与比较）。
  final String raw;

  /// 是否为预发布版本。
  bool get isPreRelease => preRelease.isNotEmpty;

  @override
  String toString() => raw;
}

/// 解析版本字符串；**永不抛异常**，无法识别的段按 0 处理。
ParsedVersion parseVersion(String input) {
  var s = input.trim();

  // 1. 去掉 GitHub tag 习惯的 `v` / `V` 前缀（仅当其后面紧跟数字时才去掉，
  //    避免把 `version1` 之类误伤成 `ersion1`）。
  if (s.length > 1 && (s[0] == 'v' || s[0] == 'V')) {
    final second = s.codeUnitAt(1);
    if (second >= 0x30 && second <= 0x39) {
      s = s.substring(1);
    }
  }

  // 2. 去掉构建元数据（`+1`、`+build.5`）—— SemVer 规定它不参与优先级比较。
  final plus = s.indexOf('+');
  if (plus >= 0) s = s.substring(0, plus);

  // 3. 拆出预发布段（第一个 `-`，如 `1.0.0-beta.2`）。
  final dash = s.indexOf('-');
  var core = s;
  var pre = '';
  if (dash >= 0) {
    core = s.substring(0, dash);
    pre = s.substring(dash + 1);
  }

  final release = <int>[];
  for (final part in core.split('.')) {
    // 非数字段（脏数据）按 0 处理，不抛异常。
    release.add(int.tryParse(part.trim()) ?? 0);
  }
  if (release.isEmpty) release.add(0);

  final preRelease = pre.isEmpty
      ? const <String>[]
      : pre.split('.').where((e) => e.isNotEmpty).toList(growable: false);

  return ParsedVersion(
    release: release,
    preRelease: preRelease,
    raw: input.trim(),
  );
}

/// 比较两个版本字符串。
///
/// 返回 `< 0` 表示 [a] 更旧，`0` 表示等价，`> 0` 表示 [a] 更新。
///
/// **不要用字符串比较代替本函数** —— 字符串比较会得出 `0.2.0 > 0.10.0`
/// 这种错误结论（逐字符 '2' > '1'）。
int compareVersions(String a, String b) {
  final va = parseVersion(a);
  final vb = parseVersion(b);

  // 1. release 段逐位比较，短的一方按 0 补齐。
  final len = va.release.length > vb.release.length
      ? va.release.length
      : vb.release.length;
  for (var i = 0; i < len; i++) {
    final x = i < va.release.length ? va.release[i] : 0;
    final y = i < vb.release.length ? vb.release[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }

  // 2. release 相同 → 正式版 > 预发布版（SemVer 规则 11）。
  if (va.preRelease.isEmpty && vb.preRelease.isEmpty) return 0;
  if (va.preRelease.isEmpty) return 1;
  if (vb.preRelease.isEmpty) return -1;

  // 3. 都带预发布标识：逐段比较，数字段按数值比，且数字段 < 字母段。
  final plen = va.preRelease.length < vb.preRelease.length
      ? va.preRelease.length
      : vb.preRelease.length;
  for (var i = 0; i < plen; i++) {
    final r = _comparePreReleasePart(va.preRelease[i], vb.preRelease[i]);
    if (r != 0) return r;
  }
  // 前缀相同 → 段数少的更小（`beta` < `beta.1`）。
  if (va.preRelease.length == vb.preRelease.length) return 0;
  return va.preRelease.length < vb.preRelease.length ? -1 : 1;
}

int _comparePreReleasePart(String a, String b) {
  final na = int.tryParse(a);
  final nb = int.tryParse(b);
  if (na != null && nb != null) {
    if (na == nb) return 0;
    return na < nb ? -1 : 1;
  }
  if (na != null) return -1; // 数字标识 < 字母标识
  if (nb != null) return 1;
  return a.compareTo(b);
}

/// [candidate] 是否比 [current] 更新（自动忽略 `v` 前缀与 `+build` 后缀）。
bool isNewerVersion(String current, String candidate) =>
    compareVersions(candidate, current) > 0;

/// 归一化版本号，便于与用户「跳过此版本」的记录做等值比较。
///
/// `v0.3.0` / `0.3.0+build` 都归一为 `0.3.0`，从而同一版本不会因写法不同
/// 被重复提示。
String normalizeVersion(String input) {
  final v = parseVersion(input);
  // 补齐到三段，保证 `1` / `1.0` / `1.0.0` 归一结果完全一致
  // （否则「跳过 v1」和「跳过 1.0.0」会被当成两个版本）。
  final parts = List<int>.of(v.release);
  while (parts.length < 3) {
    parts.add(0);
  }
  final core = parts.join('.');
  return v.preRelease.isEmpty ? core : '$core-${v.preRelease.join('.')}';
}
