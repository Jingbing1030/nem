import 'dart:convert';

import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

void main() {
  group('PBKDF2', () {
    test('RFC 6070 风格向量：确定性（同输入同输出）', () {
      final a = Kdf.pbkdf2(
        password: utf8.encode('password'),
        salt: utf8.encode('salt'),
        iterations: 1,
      );
      final b = Kdf.pbkdf2(
        password: utf8.encode('password'),
        salt: utf8.encode('salt'),
        iterations: 1,
      );
      expect(a, equals(b));
      expect(a.length, 32);
    });

    test('迭代次数影响结果', () {
      final a = Kdf.pbkdf2(
        password: utf8.encode('p'),
        salt: utf8.encode('s'),
        iterations: 1,
      );
      final b = Kdf.pbkdf2(
        password: utf8.encode('p'),
        salt: utf8.encode('s'),
        iterations: 2,
      );
      expect(a, isNot(equals(b)));
    });

    test('盐不同则结果不同', () {
      final a = Kdf.pbkdf2(
        password: utf8.encode('p'),
        salt: utf8.encode('s1'),
        iterations: 10,
      );
      final b = Kdf.pbkdf2(
        password: utf8.encode('p'),
        salt: utf8.encode('s2'),
        iterations: 10,
      );
      expect(a, isNot(equals(b)));
    });

    test('派生长度可指定', () {
      expect(
        Kdf.pbkdf2(
          password: utf8.encode('p'),
          salt: utf8.encode('s'),
          iterations: 1,
          keyLength: 16,
        ).length,
        16,
      );
    });
  });

  group('协议固定参数（不得改动）', () {
    test('盐与迭代次数与文档一致', () {
      expect(Kdf.pairSalt, 'notepad_pair_v1');
      expect(Kdf.sessionSalt, 'notepad_session_v1');
      expect(Kdf.pairIterations, 100000);
      expect(Kdf.sessionIterations, 10000);
      expect(Kdf.derivedKeyLength, 32);
    });

    test('配对密钥与会话密钥不同（即使 masterKey 恰好等于配对码）', () {
      final pairKey = Kdf.pairKey('123456');
      final sessionKey = Kdf.sessionKey('123456');
      expect(pairKey, isNot(equals(sessionKey)));
      expect(pairKey.length, 32);
      expect(sessionKey.length, 32);
    });

    test('pairKey 确定性：两台设备用同一码派出同一密钥', () {
      expect(Kdf.pairKey('483920'), equals(Kdf.pairKey('483920')));
    });

    test('sessionKey 确定性：由 masterKey 稳定派生', () {
      const mk = 'AAAAAAAABBBBBBBBCCCCCCCC';
      expect(Kdf.sessionKey(mk), equals(Kdf.sessionKey(mk)));
      expect(
        Kdf.sessionKey(mk),
        isNot(equals(Kdf.sessionKey('${mk}D'))),
      );
    });
  });

  group('masterKey 生成', () {
    test('长度 128 位（16 字节 → base64url 22 字符）', () {
      final mk = Kdf.generateMasterKey();
      expect(mk.length, 22);
      expect(base64Url.decode('$mk==').length, 16);
    });

    test('base64url 字符集且无填充', () {
      for (var i = 0; i < 50; i++) {
        final mk = Kdf.generateMasterKey();
        expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(mk), isTrue);
        expect(mk.contains('='), isFalse);
        expect(mk.contains('+'), isFalse);
        expect(mk.contains('/'), isFalse);
      }
    });

    test('多次生成互不相同（随机性）', () {
      final seen = <String>{};
      for (var i = 0; i < 200; i++) {
        seen.add(Kdf.generateMasterKey());
      }
      expect(seen.length, 200);
    });

    test('可无填充解码回 16 字节', () {
      final mk = Kdf.generateMasterKey();
      final pad = '=' * ((4 - mk.length % 4) % 4);
      expect(base64Url.decode('$mk$pad').length, 16);
    });
  });

  group('由 masterKey 派生的 TOTP 密钥', () {
    test('32 字节且确定性', () {
      const mk = 'AAAAAAAABBBBBBBBCCCCCCCC';
      final s = Kdf.totpSecret(mk);
      expect(s.length, 32);
      expect(s, equals(Kdf.totpSecret(mk)));
    });

    test('不同 masterKey 得到不同 TOTP 密钥', () {
      expect(
        Kdf.totpSecret('AAAAAAAAAAAAAAAAAAAAAA'),
        isNot(equals(Kdf.totpSecret('BBBBBBBBBBBBBBBBBBBBBB'))),
      );
    });

    test('与同 masterKey 派生的会话密钥不同（域分离）', () {
      const mk = 'AAAAAAAABBBBBBBBCCCCCCCC';
      expect(Kdf.totpSecret(mk), isNot(equals(Kdf.sessionKey(mk))));
    });
  });
}
