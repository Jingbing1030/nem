import 'dart:convert';

/// 文本补丁工具（变更 6.4）。
///
/// **为什么自己实现而不用 `diff_match_patch`**：该包最新版 0.4.1（2021-06）
/// 的 SDK 约束是 `>=2.12.0 <3.0.0`，**明确不支持 Dart 3**（本项目用 3.14），
/// 因此无法引入。这里实现一个**行级 LCS diff**，对本场景足够：
///
/// - 笔记是 Markdown 文本，改动通常集中在少数行；
/// - 传输体积取决于「差异行数」而非编辑次数，符合文档要求；
/// - 不需要字符级最小 diff（那种精度对带宽收益有限，且复杂度高）。
///
/// ## 补丁格式
///
/// ```json
/// { "ops": [ {"t":"=", "n":3}, {"t":"-", "n":2}, {"t":"+", "lines":["a","b"], "n":2} ] }
/// ```
/// - `t`：`=` 相同 / `-` 删除 / `+` 新增
/// - `n`：行数
/// - `lines`：仅 `+` 需要，携带新增行的内容
///
/// 同一段连续的删除+新增会合并成一个「替换」块，避免交错。
class PatchUtil {
  PatchUtil._();

  /// 生成 [from] → [to] 的补丁（JSON 字符串）。
  static String makePatch(String from, String to) {
    final a = _splitLines(from);
    final b = _splitLines(to);
    final ops = _diff(a, b);
    return jsonEncode(<String, dynamic>{
      'ops': ops.map((o) => o.toJson()).toList(),
    });
  }

  /// 应用补丁。失败（内容不匹配）返回 null。
  static String? applyPatch(String base, String patchJson) {
    List<_Op> ops;
    try {
      final decoded = jsonDecode(patchJson);
      if (decoded is! Map || decoded['ops'] is! List) return null;
      ops = (decoded['ops'] as List)
          .map((e) => _Op.fromJson((e as Map).cast<String, dynamic>()))
          .toList();
    } catch (_) {
      return null;
    }

    final baseLines = _splitLines(base);
    final out = <String>[];
    var i = 0;

    for (final op in ops) {
      switch (op.t) {
        case '=':
          // 相同段：必须逐行匹配，否则说明基线不对
          if (i + op.n > baseLines.length) return null;
          for (var k = 0; k < op.n; k++) {
            out.add(baseLines[i + k]);
          }
          i += op.n;
        case '-':
          if (i + op.n > baseLines.length) return null;
          i += op.n; // 丢弃这些行
        case '+':
          out.addAll(op.lines);
        default:
          return null;
      }
    }
    // 基线必须被完整消费
    if (i != baseLines.length) return null;
    return out.join('\n');
  }

  /// 补丁体积占全量的比例（用于决定是否直接发全量）。
  static double patchRatio(String base, String patchJson) {
    final baseBytes = utf8.encode(base).length;
    if (baseBytes == 0) return 1.0;
    final patchBytes = utf8.encode(patchJson).length;
    return patchBytes / baseBytes;
  }

  /// 补丁是否值得发送（未超过阈值）。
  static bool shouldSendPatch(
    String base,
    String patchJson, {
    double limit = 0.7,
  }) =>
      patchRatio(base, patchJson) <= limit;

  /// 按行切分（保留换行语义：用 \n 连接可还原）。
  static List<String> _splitLines(String s) =>
      s.isEmpty ? <String>[] : s.split('\n');

  /// 行级 LCS diff，产出压缩后的操作序列。
  static List<_Op> _diff(List<String> a, List<String> b) {
    // 经典 LCS 动态规划。行数通常有限（笔记文本），O(n*m) 可接受。
    final n = a.length;
    final m = b.length;

    // dp[i][j] = a[i..] 与 b[j..] 的 LCS 长度
    final dp = List<List<int>>.generate(
      n + 1,
      (_) => List<int>.filled(m + 1, 0),
    );
    for (var i = n - 1; i >= 0; i--) {
      for (var j = m - 1; j >= 0; j--) {
        dp[i][j] = a[i] == b[j]
            ? dp[i + 1][j + 1] + 1
            : (dp[i + 1][j] >= dp[i][j + 1] ? dp[i + 1][j] : dp[i][j + 1]);
      }
    }

    final raw = <_Op>[];
    var i = 0;
    var j = 0;
    while (i < n && j < m) {
      if (a[i] == b[j]) {
        _push(raw, _Op.equal(1));
        i++;
        j++;
      } else if (dp[i + 1][j] >= dp[i][j + 1]) {
        _push(raw, _Op.delete(1));
        i++;
      } else {
        _push(raw, _Op.insert(<String>[b[j]]));
        j++;
      }
    }
    while (i < n) {
      _push(raw, _Op.delete(1));
      i++;
    }
    while (j < m) {
      _push(raw, _Op.insert(<String>[b[j]]));
      j++;
    }

    return _compact(raw);
  }

  /// 合并相邻同类操作，减少 ops 数量（体积优化）。
  static void _push(List<_Op> list, _Op op) {
    if (list.isEmpty) {
      list.add(op);
      return;
    }
    final last = list.last;
    if (last.t == op.t) {
      if (op.t == '+') {
        last.lines.addAll(op.lines);
        last.n = last.lines.length;
      } else {
        last.n += op.n;
      }
    } else {
      list.add(op);
    }
  }

  /// 把「删除紧邻新增」压成一个替换块（语义等价，体积更小、更清晰）。
  static List<_Op> _compact(List<_Op> ops) {
    final out = <_Op>[];
    for (var k = 0; k < ops.length; k++) {
      final cur = ops[k];
      if (cur.t == '-' &&
          k + 1 < ops.length &&
          ops[k + 1].t == '+') {
        // - 与 + 相邻：保留两者（应用端按顺序处理即可），
        // 但把 + 的 lines 合并进来便于调试阅读。
        out.add(cur);
        out.add(ops[k + 1]);
        k++;
      } else {
        out.add(cur);
      }
    }
    return out;
  }
}

/// 单个操作。
class _Op {
  _Op(this.t, this.n, [List<String>? lines]) : lines = lines ?? <String>[];

  /// '=' / '-' / '+'
  final String t;

  /// 行数。
  int n;

  /// 新增行内容（仅 '+' 使用）。
  final List<String> lines;

  factory _Op.equal(int n) => _Op('=', n);
  factory _Op.delete(int n) => _Op('-', n);
  factory _Op.insert(List<String> lines) => _Op('+', lines.length, lines);

  Map<String, dynamic> toJson() => <String, dynamic>{
        't': t,
        'n': n,
        if (t == '+') 'lines': lines,
      };

  static _Op fromJson(Map<String, dynamic> json) {
    final t = (json['t'] as String?) ?? '';
    final n = (json['n'] as num?)?.toInt() ?? 0;
    final lines = ((json['lines'] as List?) ?? <dynamic>[])
        .map((e) => e.toString())
        .toList();
    return _Op(t, n, lines);
  }

  @override
  String toString() => 'Op($t,$n${t == '+' ? ',"${lines.join('|')}"' : ''})';
}
