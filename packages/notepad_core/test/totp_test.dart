import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

void main() {
  // RFC 6238 附录 B 的官方种子（ASCII）。
  final seed20 = '12345678901234567890'.codeUnits;
  final seed32 = '12345678901234567890123456789012'.codeUnits;

  group('HOTP — RFC 4226 附录 D 官方测试向量', () {
    // 官方向量使用密钥 "12345678901234567890"（20 字节，SHA-1 长度）。
    const expected = <int, String>{
      0: '755224',
      1: '287082',
      2: '359152',
      3: '969429',
      4: '338314',
      5: '254676',
      6: '287922',
      7: '162583',
      8: '399871',
      9: '520489',
    };

    expected.forEach((counter, code) {
      test('counter=$counter → $code', () {
        expect(Totp.hotp(seed20, counter), code);
      });
    });
  });

  group('TOTP — RFC 6238 附录 B 官方测试向量（SHA-1）', () {
    // RFC 6238 向量基于 20 字节种子（SHA-1 配置）。
    const vectors = <int, String>{
      59: '94287082',
      1111111109: '07081804',
      1111111111: '14050471',
      1234567890: '89005924',
      2000000000: '69279037',
      20000000000: '65353130',
    };

    vectors.forEach((unixSeconds, code) {
      test('T=$unixSeconds → $code', () {
        final t = DateTime.fromMillisecondsSinceEpoch(
          unixSeconds * 1000,
          isUtc: true,
        );
        // 官方向量是 8 位码，本项目用 6 位，因此取后 6 位比较。
        expect(Totp.totp(seed20, t, digits: 8), code);
        expect(Totp.totp(seed20, t), code.substring(2));
      });
    });
  });

  group('校验窗口 ±1（±30s）', () {
    final t = DateTime.fromMillisecondsSinceEpoch(1234567890 * 1000, isUtc: true);
    final code = Totp.totp(seed20, t);

    test('同一步内校验通过', () {
      expect(Totp.verify(code, seed20, t), isTrue);
      expect(
        Totp.verify(code, seed20, t.add(const Duration(seconds: 20))),
        isTrue,
      );
    });

    test('容错 +30s（+1 步）通过', () {
      expect(
        Totp.verify(code, seed20, t.add(const Duration(seconds: 30))),
        isTrue,
      );
    });

    test('容错 -30s（-1 步）通过', () {
      expect(
        Totp.verify(code, seed20, t.subtract(const Duration(seconds: 30))),
        isTrue,
      );
    });

    test('窗口边界：+33s 仍只跨 1 步（t 正好在步边界），应通过', () {
      // t=1234567890 恰好是 30 的整数倍，故 +33s 仅进入下一步，仍在 ±1 窗口内。
      expect(
        Totp.verify(code, seed20, t.add(const Duration(seconds: 33))),
        isTrue,
      );
    });

    test('超出 +60s（+2 步）被拒', () {
      expect(
        Totp.verify(code, seed20, t.add(const Duration(seconds: 60))),
        isFalse,
      );
    });

    test('超出 -60s（-2 步）被拒', () {
      expect(
        Totp.verify(code, seed20, t.subtract(const Duration(seconds: 60))),
        isFalse,
      );
    });

    test('错误码被拒', () {
      expect(Totp.verify('000000', seed20, t), isFalse);
      expect(Totp.verify(code, seed32, t), isFalse);
    });

    test('位数不符直接拒绝', () {
      expect(Totp.verify('12345', seed20, t), isFalse);
      expect(Totp.verify('1234567', seed20, t), isFalse);
    });

    test('码有 6 位且为纯数字（含前导零）', () {
      for (var i = 0; i < 200; i++) {
        final c = Totp.totp(seed32, t.add(Duration(seconds: i * 7)));
        expect(c.length, 6);
        expect(RegExp(r'^\d{6}$').hasMatch(c), isTrue);
      }
    });
  });

  group('步长与倒计时', () {
    test('30 秒刷新一次：同一步内码不变', () {
      final base = DateTime.fromMillisecondsSinceEpoch(1000000000 * 1000, isUtc: true);
      final a = Totp.totp(seed32, base);
      final b = Totp.totp(seed32, base.add(const Duration(seconds: 5)));
      expect(a, b);
    });

    test('跨步后码改变', () {
      final base = DateTime.fromMillisecondsSinceEpoch(1000000000 * 1000, isUtc: true);
      final a = Totp.totp(seed32, base);
      final b = Totp.totp(seed32, base.add(const Duration(seconds: 30)));
      expect(a, isNot(b));
    });

    test('倒计时在 1..30 之间', () {
      for (var i = 0; i < 60; i++) {
        final r = Totp.secondsRemaining(
          DateTime.fromMillisecondsSinceEpoch(1000000000 * 1000 + i * 1000, isUtc: true),
        );
        expect(r, inInclusiveRange(1, 30));
      }
    });
  });
}
