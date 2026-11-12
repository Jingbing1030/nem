import 'dart:convert';

import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

void main() {
  group('补丁往返：apply(make(base, new)) == new', () {
    test('无改动', () {
      const s = '# 标题\n正文\n第三行';
      final p = PatchUtil.makePatch(s, s);
      expect(PatchUtil.applyPatch(s, p), s);
    });

    test('单行修改', () {
      const a = '# 标题\n正文\n第三行';
      const b = '# 标题\n改过的正文\n第三行';
      expect(PatchUtil.applyPatch(a, PatchUtil.makePatch(a, b)), b);
    });

    test('新增一行', () {
      const a = 'A\nB';
      const b = 'A\nB\nC';
      expect(PatchUtil.applyPatch(a, PatchUtil.makePatch(a, b)), b);
    });

    test('删除一行', () {
      const a = 'A\nB\nC';
      const b = 'A\nC';
      expect(PatchUtil.applyPatch(a, PatchUtil.makePatch(a, b)), b);
    });

    test('空 ↔ 非空', () {
      expect(PatchUtil.applyPatch('', PatchUtil.makePatch('', 'hello')), 'hello');
      expect(PatchUtil.applyPatch('hello', PatchUtil.makePatch('hello', '')), '');
    });

    test('中文与 emoji', () {
      const a = '# 中文标题 🎉\n第一行\n第二行';
      const b = '# 中文标题 🎉\n第一行改\n第二行\n新增 🚀';
      expect(PatchUtil.applyPatch(a, PatchUtil.makePatch(a, b)), b);
    });

    test('末尾换行差异', () {
      expect(PatchUtil.applyPatch('a\nb', PatchUtil.makePatch('a\nb', 'a\nb\n')), 'a\nb\n');
    });

    test('整篇重写', () {
      const a = 'x\ny\nz';
      const b = '1\n2\n3';
      expect(PatchUtil.applyPatch(a, PatchUtil.makePatch(a, b)), b);
    });

    test('随机场景批量往返（100 组）', () {
      final rnd = _Rng(20261112);
      for (var t = 0; t < 100; t++) {
        final aLines = List<String>.generate(rnd.nextInt(30), (i) => 'L${rnd.nextInt(50)}');
        final bLines = List<String>.from(aLines);
        // 随机做若干改动
        for (var k = 0; k < rnd.nextInt(5); k++) {
          final op = rnd.nextInt(3);
          if (op == 0 && bLines.isNotEmpty) {
            bLines.removeAt(rnd.nextInt(bLines.length));
          } else if (op == 1) {
            bLines.insert(rnd.nextInt(bLines.length + 1), 'NEW${rnd.nextInt(999)}');
          } else if (bLines.isNotEmpty) {
            bLines[rnd.nextInt(bLines.length)] = 'MOD${rnd.nextInt(999)}';
          }
        }
        final a = aLines.join('\n');
        final b = bLines.join('\n');
        expect(
          PatchUtil.applyPatch(a, PatchUtil.makePatch(a, b)),
          b,
          reason: '第 $t 组：$a → $b',
        );
      }
    });
  });

  group('变更 10 验收项：离线编辑 100 次 → 单个 patch，体积与次数无关', () {
    test('把「从基线到最终」一次生成的 patch 远小于全量', () {
      final base = List<String>.generate(500, (i) => '行 $i 内容').join('\n');

      // 模拟离线期间 100 次编辑，最终只改了 3 行
      var cur = base;
      for (var i = 0; i < 100; i++) {
        final lines = cur.split('\n');
        lines[10] = '第 $i 次编辑';
        cur = lines.join('\n');
      }
      final lines = cur.split('\n')
        ..[20] = '另一处改动'
        ..[30] = '第三处改动';
      cur = lines.join('\n');

      final patch = PatchUtil.makePatch(base, cur);

      // 关键断言：patch 体积与「编辑次数」无关，只与差异量有关
      final ratio = PatchUtil.patchRatio(base, patch);
      expect(ratio, lessThan(0.5), reason: '500 行里只改 3 行，patch 应远小于全量');

      // 且能正确应用
      expect(PatchUtil.applyPatch(base, patch), cur);
    });

    test('patch 体积随差异行数增长，而非编辑次数', () {
      final base = List<String>.generate(300, (i) => '行 $i').join('\n');

      // 改 1 行：编辑 100 次但最终只留 1 处差异
      var one = base;
      for (var i = 0; i < 100; i++) {
        final l = one.split('\n')..[5] = '编辑$i';
        one = l.join('\n');
      }
      final patchOne = PatchUtil.makePatch(base, one);

      // 改 50 行
      final l50 = base.split('\n');
      for (var i = 0; i < 50; i++) {
        l50[i] = '改了$i';
      }
      final patch50 = PatchUtil.makePatch(base, l50.join('\n'));

      expect(
        utf8.encode(patchOne).length,
        lessThan(utf8.encode(patch50).length),
        reason: '差异行少 → patch 更小',
      );
    });

    test('体积超过 70% 时判定为不值得发 patch', () {
      final base = List<String>.generate(10, (i) => '短行$i').join('\n');
      final rewritten = List<String>.generate(10, (i) => '完全不同的很长的内容$i' * 3).join('\n');
      final patch = PatchUtil.makePatch(base, rewritten);

      expect(PatchUtil.patchRatio(base, patch), greaterThan(0.7));
      expect(PatchUtil.shouldSendPatch(base, patch), isFalse);
      expect(
        PatchUtil.shouldSendPatch(base, patch, limit: 100.0),
        isTrue,
      );
    });
  });

  group('applyPatch 的健壮性（版本不匹配应失败而非静默出错）', () {
    test('基线不匹配 → 返回 null', () {
      const base = 'A\nB\nC';
      final patch = PatchUtil.makePatch(base, 'A\nB\nD');
      // 用错误的基线应用：上下文行（A/B）不匹配
      expect(
        PatchUtil.applyPatch('X\nY\nZ\nW', patch),
        isNull,
        reason: '行数与上下文都不匹配时应失败',
      );
    });

    test('非法 JSON → 返回 null', () {
      expect(PatchUtil.applyPatch('a', 'not json'), isNull);
      expect(PatchUtil.applyPatch('a', '{}'), isNull);
      expect(PatchUtil.applyPatch('a', '{"ops":"bad"}'), isNull);
    });

    test('未知操作类型 → 返回 null', () {
      final bad = jsonEncode(<String, dynamic>{
        'ops': <dynamic>[
          <String, dynamic>{'t': '?', 'n': 1},
        ],
      });
      expect(PatchUtil.applyPatch('a', bad), isNull);
    });

    test('基线被完整消费才算成功（多余内容 → null）', () {
      const base = 'A\nB';
      // patch 只消费 A，base 还剩 B → 应失败
      final bad = jsonEncode(<String, dynamic>{
        'ops': <dynamic>[
          <String, dynamic>{'t': '=', 'n': 1},
        ],
      });
      expect(PatchUtil.applyPatch(base, bad), isNull);
    });

    test('空补丁应用到空串成功', () {
      final patch = PatchUtil.makePatch('', '');
      expect(PatchUtil.applyPatch('', patch), '');
    });
  });

  group('补丁体积（变更 10 验收项：1MB 笔记改 3 处 < 50KB）', () {
    test('1MB 笔记改 3 处，patch 远小于 50KB', () {
      // 构造约 1MB 的文本
      final base = List<String>.generate(20000, (i) => '这是第 $i 行的内容，用来撑大体积').join('\n');
      final baseBytes = utf8.encode(base).length;
      expect(baseBytes, greaterThan(700 * 1024));

      final lines = base.split('\n')
        ..[100] = '改动一'
        ..[5000] = '改动二'
        ..[15000] = '改动三';
      final patched = lines.join('\n');

      final patch = PatchUtil.makePatch(base, patched);
      final patchBytes = utf8.encode(patch).length;

      expect(patchBytes, lessThan(50 * 1024), reason: '实际 ${patchBytes}B');
      expect(PatchUtil.applyPatch(base, patch), patched);
    });
  });

  group('补丁 ops 结构', () {
    test('ops 是合法的 JSON 且含 t/n', () {
      final patch = PatchUtil.makePatch('A\nB', 'A\nC');
      final j = jsonDecode(patch) as Map<String, dynamic>;
      final ops = j['ops'] as List;
      expect(ops, isNotEmpty);
      for (final o in ops) {
        final m = o as Map;
        expect(m['t'], isIn(<String>['=', '-', '+']));
        expect(m['n'], isA<int>());
      }
    });

    test('新增操作的 ops 携带 lines', () {
      final patch = PatchUtil.makePatch('A', 'A\nB');
      final j = jsonDecode(patch) as Map<String, dynamic>;
      final plus = (j['ops'] as List).cast<Map>()
          .firstWhere((m) => m['t'] == '+');
      expect(plus['lines'], contains('B'));
    });

    test('相邻同类操作被合并（体积优化）', () {
      // 连续新增 5 行应合并成 1 个 + 操作
      final patch = PatchUtil.makePatch('A', 'A\n1\n2\n3\n4\n5');
      final j = jsonDecode(patch) as Map<String, dynamic>;
      final plusOps = (j['ops'] as List).where((m) => (m as Map)['t'] == '+').length;
      expect(plusOps, 1);
    });
  });
}

/// 可复现的伪随机数（避免测试不稳定）。
class _Rng {
  _Rng(this._seed);
  int _seed;
  int nextInt(int max) {
    _seed = (_seed * 1103515245 + 12345) & 0x7fffffff;
    return max <= 0 ? 0 : _seed % max;
  }
}
