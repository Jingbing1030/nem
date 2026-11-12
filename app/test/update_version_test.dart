import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/update/version.dart';

/// 版本比较是本功能唯一的「算法」，也是最容易写错的地方
/// （按字符串比会把 `0.2.0` 判成比 `0.10.0` 新）。
/// 这里覆盖需求点名的边界 + SemVer 规范里的边角。
void main() {
  group('compareVersions —— 位宽与数值（不能按字符串比）', () {
    test('0.9.0 < 0.10.0（字符串比较会得出相反结论）', () {
      expect(compareVersions('0.9.0', '0.10.0'), lessThan(0));
      expect(compareVersions('0.10.0', '0.9.0'), greaterThan(0));
    });

    test('1.0.0 > 0.9.9', () {
      expect(compareVersions('1.0.0', '0.9.9'), greaterThan(0));
    });

    test('0.2.0 < 0.10.0（本项目的真实场景：当前版本 vs 新版本）', () {
      expect(compareVersions('0.2.0', '0.10.0'), lessThan(0));
      expect(isNewerVersion('0.2.0', '0.10.0'), isTrue);
    });

    test('大数值段按整数比较，不受位数影响', () {
      expect(compareVersions('1.9.0', '1.10.0'), lessThan(0));
      expect(compareVersions('1.2.100', '1.2.99'), greaterThan(0));
      expect(compareVersions('10.0.0', '9.99.99'), greaterThan(0));
    });

    test('相等版本返回 0', () {
      expect(compareVersions('0.2.0', '0.2.0'), 0);
      expect(compareVersions('1.2.3', '1.2.3'), 0);
    });

    test('major / minor / patch 任一位不同都能判出方向', () {
      expect(compareVersions('2.0.0', '1.99.99'), greaterThan(0));
      expect(compareVersions('1.3.0', '1.2.99'), greaterThan(0));
      expect(compareVersions('1.2.4', '1.2.3'), greaterThan(0));
    });
  });

  group('compareVersions —— v 前缀 / 位数不等 / +build 后缀', () {
    test('v 前缀被忽略：v0.3.0 == 0.3.0', () {
      expect(compareVersions('v0.3.0', '0.3.0'), 0);
      expect(compareVersions('0.3.0', 'v0.3.0'), 0);
      expect(compareVersions('v1.0.0', 'v0.9.9'), greaterThan(0));
      expect(compareVersions('V1.0.0', 'v0.9.9'), greaterThan(0));
    });

    test('v 后面不是数字时不去掉前缀（避免误伤）', () {
      // 'version' 不该被切成 'ersion'；整段按脏数据处理，不抛异常。
      expect(() => parseVersion('version'), returnsNormally);
    });

    test('位数不等按缺位补 0：1.0 == 1.0.0 == 1.0.0.0', () {
      expect(compareVersions('1.0', '1.0.0'), 0);
      expect(compareVersions('1.0.0.0', '1.0.0'), 0);
      expect(compareVersions('1.0', '1.0.1'), lessThan(0));
      expect(compareVersions('1', '1.0.0'), 0);
    });

    test('+build 元数据不参与比较（pubspec 的 0.2.0+1）', () {
      expect(compareVersions('0.2.0+1', '0.2.0'), 0);
      expect(compareVersions('0.2.0+99', '0.2.0+1'), 0);
      // 关键场景：当前 0.2.0+1 vs 远端 v0.2.0 → 不算更新。
      expect(isNewerVersion('0.2.0+1', 'v0.2.0'), isFalse);
      // 远端 0.3.0+build.7 vs 当前 0.2.0+1 → 算更新。
      expect(isNewerVersion('0.2.0+1', 'v0.3.0+build.7'), isTrue);
    });

    test('前后空格被容忍', () {
      expect(compareVersions(' 0.3.0 ', '0.3.0'), 0);
      expect(isNewerVersion('0.2.0', ' v0.3.0\n'), isTrue);
    });
  });

  group('compareVersions —— 预发布版本（SemVer 规则）', () {
    test('同号正式版 > 预发布版', () {
      expect(compareVersions('1.0.0', '1.0.0-beta'), greaterThan(0));
      expect(compareVersions('1.0.0-beta', '1.0.0'), lessThan(0));
      expect(isNewerVersion('1.0.0-beta', '1.0.0'), isTrue);
    });

    test('预发布版之间逐段比较，数字段按数值比', () {
      expect(compareVersions('1.0.0-beta.2', '1.0.0-beta.10'), lessThan(0));
      expect(compareVersions('1.0.0-beta.10', '1.0.0-beta.2'), greaterThan(0));
      expect(compareVersions('1.0.0-alpha', '1.0.0-beta'), lessThan(0));
    });

    test('段数少的预发布版更小（beta < beta.1）', () {
      expect(compareVersions('1.0.0-beta', '1.0.0-beta.1'), lessThan(0));
      expect(compareVersions('1.0.0-beta.1', '1.0.0-beta'), greaterThan(0));
    });

    test('更高的预发布版仍大于更低的正式版', () {
      expect(compareVersions('1.1.0-rc.1', '1.0.0'), greaterThan(0));
    });
  });

  group('isNewerVersion —— 真实使用场景', () {
    test('当前 0.2.0+1 的判定表', () {
      // 远端相等或更旧 → 不提示
      expect(isNewerVersion('0.2.0+1', 'v0.2.0'), isFalse);
      expect(isNewerVersion('0.2.0+1', 'v0.1.9'), isFalse);
      // 远端更新 → 提示
      expect(isNewerVersion('0.2.0+1', 'v0.2.1'), isTrue);
      expect(isNewerVersion('0.2.0+1', 'v0.3.0'), isTrue);
      expect(isNewerVersion('0.2.0+1', 'v1.0.0'), isTrue);
      // 跨位宽（最容易出错的一档）
      expect(isNewerVersion('0.2.0+1', 'v0.10.0'), isTrue);
      expect(isNewerVersion('0.2.0+1', 'v0.20.0'), isTrue);
    });
  });

  group('normalizeVersion —— 归一化用于「跳过此版本」等值比较', () {
    test('去掉 v 前缀与 +build', () {
      expect(normalizeVersion('v0.3.0'), '0.3.0');
      expect(normalizeVersion('0.3.0+12'), '0.3.0');
      expect(normalizeVersion('0.2.0+1'), '0.2.0');
      expect(normalizeVersion(' v1.0.0+build.5 '), '1.0.0');
    });

    test('补齐缺位（保证 1.0 与 1.0.0 归一结果一致）', () {
      expect(normalizeVersion('1.0'), '1.0.0');
      expect(normalizeVersion('1.0.0'), '1.0.0');
      expect(normalizeVersion('1'), '1.0.0');
    });

    test('保留预发布段', () {
      expect(normalizeVersion('v1.0.0-beta.2'), '1.0.0-beta.2');
    });

    test('归一化后等值 ⟺ 版本等价', () {
      expect(normalizeVersion('v0.2.0'), normalizeVersion('0.2.0+1'));
      expect(compareVersions('v0.2.0', '0.2.0+1'), 0);
    });
  });

  group('脏数据不抛异常（更新检测不能因版本格式怪异而崩）', () {
    test('各种畸形输入都 returnsNormally', () {
      for (final s in <String>[
        '',
        '   ',
        'v',
        'latest',
        '1.x.0',
        '...',
        '1.2.3.4.5.6',
        '-beta',
        '+1',
      ]) {
        expect(() => parseVersion(s), returnsNormally, reason: '输入: "$s"');
        expect(() => compareVersions(s, '0.2.0'), returnsNormally,
            reason: '输入: "$s"');
      }
    });

    test('非数字段按 0 处理', () {
      expect(parseVersion('1.x.0').release, <int>[1, 0, 0]);
      expect(compareVersions('1.x.0', '1.0.0'), 0);
    });

    test('空串等价于 0.0.0', () {
      expect(compareVersions('', '0.0.0'), 0);
      expect(parseVersion('').release, <int>[0]);
    });
  });

  group('parseVersion 的结构', () {
    test('拆出 release 与 preRelease', () {
      final v = parseVersion('v1.2.3-beta.4+build.5');
      expect(v.release, <int>[1, 2, 3]);
      expect(v.preRelease, <String>['beta', '4']);
      expect(v.isPreRelease, isTrue);
      expect(v.raw, 'v1.2.3-beta.4+build.5');
    });

    test('正式版 preRelease 为空', () {
      final v = parseVersion('0.2.0+1');
      expect(v.release, <int>[0, 2, 0]);
      expect(v.preRelease, isEmpty);
      expect(v.isPreRelease, isFalse);
    });
  });
}
