import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/net/pairing_guard.dart';

void main() {
  final t0 = DateTime(2026, 11, 12, 10, 0, 0);

  group('配对失败限流（需求 5.5：3 次失败锁 60s）', () {
    test('未失败时未锁定', () {
      final g = PairingGuard();
      expect(g.isLocked('1.2.3.4', now: t0), isFalse);
      expect(g.lockRemainingSeconds('1.2.3.4', now: t0), 0);
    });

    test('失败 1 次、2 次均不锁定', () {
      final g = PairingGuard();
      g.recordFailure('1.2.3.4', now: t0);
      expect(g.isLocked('1.2.3.4', now: t0), isFalse);
      g.recordFailure('1.2.3.4', now: t0);
      expect(g.isLocked('1.2.3.4', now: t0), isFalse);
      expect(g.failureCount('1.2.3.4', now: t0), 2);
    });

    test('第 3 次失败 → 立即锁定', () {
      final g = PairingGuard();
      for (var i = 0; i < 3; i++) {
        g.recordFailure('1.2.3.4', now: t0);
      }
      expect(g.isLocked('1.2.3.4', now: t0), isTrue);
    });

    test('锁定 60 秒后自动解锁', () {
      final g = PairingGuard();
      for (var i = 0; i < 3; i++) {
        g.recordFailure('1.2.3.4', now: t0);
      }
      expect(g.isLocked('1.2.3.4', now: t0.add(const Duration(seconds: 30))), isTrue);
      expect(g.isLocked('1.2.3.4', now: t0.add(const Duration(seconds: 61))), isFalse);
    });

    test('剩余秒数递减且在合理范围', () {
      final g = PairingGuard();
      for (var i = 0; i < 3; i++) {
        g.recordFailure('1.2.3.4', now: t0);
      }
      final r = g.lockRemainingSeconds('1.2.3.4', now: t0);
      expect(r, inInclusiveRange(1, 61));
      expect(
        g.lockRemainingSeconds('1.2.3.4', now: t0.add(const Duration(seconds: 50))),
        lessThanOrEqualTo(r),
      );
    });

    test('锁定状态按 IP 隔离', () {
      final g = PairingGuard();
      for (var i = 0; i < 3; i++) {
        g.recordFailure('1.2.3.4', now: t0);
      }
      expect(g.isLocked('1.2.3.4', now: t0), isTrue);
      expect(g.isLocked('5.6.7.8', now: t0), isFalse);
    });

    test('配对成功后清除失败记录', () {
      final g = PairingGuard();
      g.recordFailure('1.2.3.4', now: t0);
      g.recordFailure('1.2.3.4', now: t0);
      g.recordSuccess('1.2.3.4');
      expect(g.failureCount('1.2.3.4', now: t0), 0);
      g.recordFailure('1.2.3.4', now: t0);
      expect(g.isLocked('1.2.3.4', now: t0), isFalse);
    });

    test('超出统计窗口的旧失败不计入', () {
      final g = PairingGuard();
      g.recordFailure('1.2.3.4', now: t0);
      g.recordFailure('1.2.3.4', now: t0);
      // 70 秒后再失败一次：前两次已出窗口，不应锁定
      final later = t0.add(const Duration(seconds: 70));
      g.recordFailure('1.2.3.4', now: later);
      expect(g.isLocked('1.2.3.4', now: later), isFalse);
    });

    test('默认参数与协议常量一致', () {
      final g = PairingGuard();
      expect(g.failureLimit, 3);
      expect(g.lockout, const Duration(seconds: 60));
    });
  });

  group('从 socket 取对端 IP', () {
    test('能取到回环地址', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final client = await Socket.connect('127.0.0.1', server.port);
      final accepted = await server.first;
      expect(PairingGuard.ipOf(accepted), '127.0.0.1');
      await client.close();
      await accepted.close();
      await server.close();
    });
  });
}
