import 'dart:convert';

import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

void main() {
  VersionVector vv(Map<String, int> m) => VersionVector(m);

  group('变更 10 验收项：equal / dominates / dominated / concurrent', () {
    test('equal：完全相同', () {
      expect(vv({'a': 1, 'b': 2}).compare(vv({'a': 1, 'b': 2})),
          VersionRelation.equal);
    });

    test('equal：空向量之间', () {
      expect(VersionVector.empty().compare(VersionVector.empty()),
          VersionRelation.equal);
    });

    test('equal：缺席键视为 0（{a:0} == {}）', () {
      expect(vv({'a': 0}).compare(VersionVector.empty()), VersionRelation.equal);
      expect(VersionVector.empty().compare(vv({'a': 0})), VersionRelation.equal);
    });

    test('dominates：本向量各项 ≥ 对方且至少一项 >', () {
      expect(vv({'a': 2, 'b': 1}).compare(vv({'a': 1, 'b': 1})),
          VersionRelation.dominates);
      expect(vv({'a': 1, 'b': 3}).compare(vv({'a': 1, 'b': 1})),
          VersionRelation.dominates);
    });

    test('dominates：对方缺席的设备也算被支配', () {
      expect(vv({'a': 1}).compare(VersionVector.empty()),
          VersionRelation.dominates);
    });

    test('dominated：本向量各项 ≤ 对方且至少一项 <', () {
      expect(vv({'a': 1, 'b': 1}).compare(vv({'a': 2, 'b': 1})),
          VersionRelation.dominated);
      expect(VersionVector.empty().compare(vv({'a': 1})),
          VersionRelation.dominated);
    });

    test('concurrent：各有领先项（真实并发编辑）', () {
      // A 设备本地 +1；B 设备本地 +1 —— 双方互不支配
      expect(vv({'a': 2, 'b': 1}).compare(vv({'a': 1, 'b': 2})),
          VersionRelation.concurrent);
      expect(vv({'a': 1, 'b': 2}).compare(vv({'a': 2, 'b': 1})),
          VersionRelation.concurrent);
    });

    test('concurrent：一方有对方没有的设备、且对方在共同设备上更超前', () {
      expect(vv({'a': 1, 'c': 1}).compare(vv({'a': 2})),
          VersionRelation.concurrent);
    });

    test('dominates / dominated 互为反向', () {
      final x = vv({'a': 3});
      final y = vv({'a': 1});
      expect(x.compare(y), VersionRelation.dominates);
      expect(y.compare(x), VersionRelation.dominated);
    });

    test('concurrent 是对称的', () {
      final x = vv({'a': 2, 'b': 1});
      final y = vv({'a': 1, 'b': 2});
      expect(x.compare(y), VersionRelation.concurrent);
      expect(y.compare(x), VersionRelation.concurrent);
    });

    test('三设备场景：只有一项领先仍是 concurrent', () {
      expect(
        vv({'a': 1, 'b': 1, 'c': 2}).compare(vv({'a': 1, 'b': 1, 'c': 1})),
        VersionRelation.dominates,
      );
      expect(
        vv({'a': 2, 'b': 1, 'c': 1}).compare(vv({'a': 1, 'b': 2, 'c': 1})),
        VersionRelation.concurrent,
      );
    });

    test('increment 后对自己是 dominates', () {
      final base = vv({'a': 1});
      expect(base.increment('a').dominates(base), isTrue);
      expect(base.increment('a').compare(base), VersionRelation.dominates);
    });

    test('increment 新设备 → dominates 原向量', () {
      final base = vv({'a': 1});
      final next = base.increment('b');
      expect(next.compare(base), VersionRelation.dominates);
    });
  });

  group('increment 与 merge', () {
    test('increment 指定设备计数 +1', () {
      expect(vv({'a': 1}).increment('a')['a'], 2);
      expect(vv({}).increment('a')['a'], 1);
    });

    test('increment 不影响其他设备与不可变性', () {
      final base = vv({'a': 1, 'b': 5});
      final next = base.increment('a');
      expect(next['b'], 5);
      expect(base['a'], 1, reason: '原向量不应被修改');
    });

    test('连续 increment 累加', () {
      var v = VersionVector.empty();
      for (var i = 0; i < 100; i++) {
        v = v.increment('dev');
      }
      expect(v['dev'], 100);
    });

    test('merge 取逐项最大值', () {
      final m = vv({'a': 3, 'b': 1}).merge(vv({'a': 1, 'b': 7, 'c': 2}));
      expect(m['a'], 3);
      expect(m['b'], 7);
      expect(m['c'], 2);
    });

    test('merge 结果支配两个输入', () {
      final x = vv({'a': 3, 'b': 1});
      final y = vv({'a': 1, 'b': 7});
      final m = x.merge(y);
      expect(m.compare(x), VersionRelation.dominates);
      expect(m.compare(y), VersionRelation.dominates);
    });

    test('merge 相同向量 → equal', () {
      final x = vv({'a': 1});
      expect(x.merge(x).compare(x), VersionRelation.equal);
    });

    test('merge 与顺序无关（交换律）', () {
      final x = vv({'a': 3, 'b': 1});
      final y = vv({'a': 1, 'b': 7});
      expect(x.merge(y), equals(y.merge(x)));
    });
  });

  group('serialize / deserialize', () {
    test('JSON 往返无损', () {
      final v = vv({'a': 1, 'b': 2, 'dev-uuid': 99});
      final back = VersionVector.decode(v.encode());
      expect(back, equals(v));
      expect(back.compare(v), VersionRelation.equal);
    });

    test('空向量往返', () {
      expect(VersionVector.decode(VersionVector.empty().encode()).isEmpty, isTrue);
    });

    test('非法 JSON → 空向量（不抛异常）', () {
      expect(VersionVector.decode('not json').isEmpty, isTrue);
      expect(VersionVector.decode('[]').isEmpty, isTrue);
      expect(VersionVector.decode('').isEmpty, isTrue);
    });

    test('值类型容错：字符串数字也能解析', () {
      final v = VersionVector.decode('{"a":"3"}');
      expect(v['a'], 3);
    });

    test('非法值按 0 处理', () {
      expect(VersionVector.decode('{"a":"abc"}')['a'], 0);
    });

    test('编码结果是合法 JSON 对象', () {
      final raw = vv({'a': 1}).encode();
      expect(jsonDecode(raw), isA<Map<String, dynamic>>());
    });

    test('可用作数据库 TEXT 列（往返后相等）', () {
      final v = vv({'d1': 5, 'd2': 3});
      expect(VersionVector.decode(v.encode()), equals(v));
      expect(VersionVector.decode(v.encode()).hashCode, v.hashCode);
    });
  });

  group('peerUnchangedSince：判断能否安全发 patch（变更 6.3）', () {
    test('对端基线未动 → 相同 → 可发 patch', () {
      final baseline = vv({'a': 1, 'b': 2});
      expect(vv({'a': 1, 'b': 2}).peerUnchangedSince(baseline), isTrue);
    });

    test('对端有推进 → 不能直接发 patch', () {
      final baseline = vv({'a': 1});
      expect(vv({'a': 1, 'b': 1}).peerUnchangedSince(baseline), isFalse);
    });

    test('对端推进了本地设备的计数 → 也不算未动', () {
      final baseline = vv({'a': 1});
      expect(vv({'a': 2}).peerUnchangedSince(baseline), isFalse);
    });
  });

  group('deviceIds / isEmpty', () {
    test('deviceIds 列出所有设备', () {
      expect(vv({'a': 1, 'b': 0}).deviceIds, {'a', 'b'});
    });

    test('isEmpty 只对全 0 为真', () {
      expect(VersionVector.empty().isEmpty, isTrue);
      expect(vv({'a': 0}).isEmpty, isTrue);
      expect(vv({'a': 1}).isEmpty, isFalse);
    });
  });
}
