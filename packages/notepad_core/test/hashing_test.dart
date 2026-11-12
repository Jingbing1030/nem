import 'dart:convert';
import 'dart:io';

import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

void main() {
  group('SHA-256', () {
    test('空输入的官方摘要', () {
      expect(
        Hashing.sha256Hex(<int>[]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });

    test('"abc" 的官方摘要', () {
      expect(
        Hashing.sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });

    test('小写十六进制且长度 64', () {
      final h = Hashing.sha256Hex(utf8.encode('局域网记事本'));
      expect(h.length, 64);
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(h), isTrue);
    });

    test('相同内容哈希相同 —— 内容寻址天然去重的依据', () {
      final img = List<int>.generate(5000, (i) => (i * 7) & 0xff);
      expect(Hashing.sha256Hex(img), Hashing.sha256Hex(List<int>.from(img)));
    });

    test('内容差一位则哈希不同', () {
      final a = List<int>.filled(100, 0);
      final b = List<int>.from(a);
      b[99] = 1;
      expect(Hashing.sha256Hex(a), isNot(Hashing.sha256Hex(b)));
    });

    test('matchesSha256 大小写不敏感', () {
      final h = Hashing.sha256Hex(utf8.encode('x'));
      expect(Hashing.matchesSha256(utf8.encode('x'), h), isTrue);
      expect(Hashing.matchesSha256(utf8.encode('x'), h.toUpperCase()), isTrue);
      expect(Hashing.matchesSha256(utf8.encode('y'), h), isFalse);
    });
  });

  group('文件 SHA-256（流式）', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('hash_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('与内存计算结果一致', () async {
      final bytes = List<int>.generate(300000, (i) => (i * 13) & 0xff);
      final f = File('${dir.path}/blob.bin')
        ..writeAsBytesSync(List<int>.from(bytes));
      expect(await Hashing.sha256File(f), Hashing.sha256Hex(bytes));
    });

    test('空文件哈希等于空输入哈希', () async {
      final f = File('${dir.path}/empty.bin')..writeAsBytesSync(<int>[]);
      expect(
        await Hashing.sha256File(f),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
    });
  });

  group('SHA-1 / HMAC-SHA1', () {
    test('"abc" 的 SHA-1 官方摘要', () {
      expect(Hashing.sha1Hex(utf8.encode('abc')), 'a9993e364706816aba3e25717850c26c9cd0d89d');
    });

    test('HMAC-SHA1 对 RFC 2202 向量（key="key"）', () {
      expect(
        Hashing.hmacSha1Hex(
          utf8.encode('key'),
          utf8.encode('The quick brown fox jumps over the lazy dog'),
        ),
        'de7c9b85b8b78aa6bc8a7a36f70a90701c9db4d9',
      );
    });
  });
}
