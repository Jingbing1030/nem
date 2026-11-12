import 'dart:convert';
import 'dart:typed_data';

import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i));

  group('AES-GCM', () {
    test('加解密往返：UTF-8 文本', () {
      const text = '局域网记事本 # 测试 🎉';
      final ct = AesGcm.encrypt(key, utf8.encode(text));
      final pt = AesGcm.decrypt(key, ct);
      expect(utf8.decode(pt), text);
    });

    test('加解密往返：空载荷', () {
      final ct = AesGcm.encrypt(key, <int>[]);
      expect(AesGcm.decrypt(key, ct), isEmpty);
    });

    test('加解密往返：1MB 大载荷', () {
      final data = Uint8List.fromList(
        List<int>.generate(1024 * 1024, (i) => (i * 31) & 0xff),
      );
      final ct = AesGcm.encrypt(key, data);
      expect(AesGcm.decrypt(key, ct), equals(data));
    });

    test('IV 为 12 字节、tag 为 16 字节', () {
      final ct = AesGcm.encrypt(key, utf8.encode('x'));
      expect(ct.nonce.length, 12);
      expect(ct.tag.length, 16);
    });

    test('两次加密同一明文产生不同密文（IV 随机）', () {
      final a = AesGcm.encrypt(key, utf8.encode('same'));
      final b = AesGcm.encrypt(key, utf8.encode('same'));
      expect(a.nonce, isNot(equals(b.nonce)));
      expect(a.ciphertext, isNot(equals(b.ciphertext)));
    });

    test('GCM 篡改检测：翻转密文一位应解密失败', () {
      final ct = AesGcm.encrypt(key, utf8.encode('integrity matters'));
      final tampered = Uint8List.fromList(ct.ciphertext);
      tampered[0] ^= 0x01;
      final bad = EncryptedPayload(
        nonce: ct.nonce,
        ciphertext: tampered,
        tag: ct.tag,
      );
      expect(
        () => AesGcm.decrypt(key, bad),
        throwsA(isA<InvalidCipherTextException>()),
      );
    });

    test('GCM 篡改检测：翻转 tag 一位应解密失败', () {
      final ct = AesGcm.encrypt(key, utf8.encode('integrity matters'));
      final badTag = Uint8List.fromList(ct.tag);
      badTag[15] ^= 0x80;
      final bad = EncryptedPayload(
        nonce: ct.nonce,
        ciphertext: ct.ciphertext,
        tag: badTag,
      );
      expect(AesGcm.tryDecrypt(key, bad), isNull);
    });

    test('GCM 篡改检测：翻转 nonce 应解密失败', () {
      final ct = AesGcm.encrypt(key, utf8.encode('integrity matters'));
      final badIv = Uint8List.fromList(ct.nonce);
      badIv[0] ^= 0x01;
      final bad = EncryptedPayload(
        nonce: badIv,
        ciphertext: ct.ciphertext,
        tag: ct.tag,
      );
      expect(AesGcm.tryDecrypt(key, bad), isNull);
    });

    test('错误密钥无法解密（这正是 fast_auth 的认证依据）', () {
      final ct = AesGcm.encrypt(key, utf8.encode('secret'));
      final wrongKey = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));
      expect(AesGcm.tryDecrypt(wrongKey, ct), isNull);
    });

    test('AAD 参与认证：AAD 不匹配则失败', () {
      final aad = Uint8List.fromList(utf8.encode('header'));
      final ct = AesGcm.encrypt(key, utf8.encode('body'), aad: aad);
      expect(utf8.decode(AesGcm.decrypt(key, ct, aad: aad)), 'body');
      final otherAad = Uint8List.fromList(utf8.encode('other'));
      expect(AesGcm.tryDecrypt(key, ct, aad: otherAad), isNull);
    });

    test('密钥长度不是 32 字节时拒绝', () {
      expect(
        () => AesGcm.encrypt(Uint8List(16), utf8.encode('x')),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('tag 长度异常时拒绝', () {
      final ct = AesGcm.encrypt(key, utf8.encode('x'));
      final bad = EncryptedPayload(
        nonce: ct.nonce,
        ciphertext: ct.ciphertext,
        tag: Uint8List(8),
      );
      expect(() => AesGcm.decrypt(key, bad), throwsA(isA<ArgumentError>()));
    });
  });
}
