import 'dart:convert';
import 'dart:typed_data';

import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

void main() {
  final key = Uint8List.fromList(List<int>.generate(32, (i) => i + 1));
  final otherKey = Uint8List.fromList(List<int>.generate(32, (i) => 99 - i));

  group('Envelope 编解码', () {
    test('JSON 往返保持四字段', () {
      final session = SecureSession(key: key);
      final env = session.seal(MsgType.noteList, {'notes': []});
      final decoded = Envelope.decode(env.encode());
      expect(decoded.type, MsgType.noteList);
      expect(decoded.payload.nonce.length, 12);
      expect(decoded.payload.tag.length, 16);
    });

    test('信封字段名与协议一致', () {
      final env = SecureSession(key: key).seal(MsgType.ping, {'ts': 1});
      final json = jsonDecode(env.encode()) as Map<String, dynamic>;
      expect(json.keys.toSet(), {'type', 'nonce', 'payload', 'tag'});
    });

    test('type 是明文（用于路由），敏感内容不出现在明文里', () {
      final env = SecureSession(key: key)
          .seal(MsgType.pairSuccess, {'masterKey': 'SUPER_SECRET_KEY'});
      final raw = env.encode();
      expect(raw.contains('SUPER_SECRET_KEY'), isFalse);
      expect(raw.contains('pair_success'), isTrue);
    });
  });

  group('SecureSession 加解密', () {
    test('seal / open 往返', () {
      final a = SecureSession(key: key);
      final b = SecureSession(key: key);
      final env = a.seal(MsgType.notePush, {
        'noteId': 'abc',
        'content': '# 标题\n正文',
        'updatedAt': '2026-11-12T00:00:00Z',
      });
      final body = b.open(env);
      expect(body['noteId'], 'abc');
      expect(body['content'], '# 标题\n正文');
    });

    test('中文与 emoji 往返正确', () {
      final a = SecureSession(key: key);
      final b = SecureSession(key: key);
      final text = '中文测试 🎉 换行\n制表\t引号"\'';
      final body = b.open(a.seal(MsgType.notePush, {'content': text}));
      expect(body['content'], text);
    });

    test('密钥不匹配 → GCM 认证失败', () {
      final env = SecureSession(key: key).seal(MsgType.ping, {'ts': 1});
      expect(
        () => SecureSession(key: otherKey).open(env),
        throwsA(isA<EnvelopeException>()),
      );
    });
  });

  group('抗攻击（验收清单安全项）', () {
    test('密文被篡改 → 解密失败并抛异常（调用方据此断开）', () {
      final env = SecureSession(key: key).seal(MsgType.notePush, {'content': 'x'});
      final tamperedCt = Uint8List.fromList(env.payload.ciphertext);
      tamperedCt[0] ^= 0xff;
      final tampered = Envelope(
        type: env.type,
        payload: EncryptedPayload(
          nonce: env.payload.nonce,
          ciphertext: tamperedCt,
          tag: env.payload.tag,
        ),
      );
      expect(
        () => SecureSession(key: key).open(tampered),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('tag 被篡改 → 失败', () {
      final env = SecureSession(key: key).seal(MsgType.ping, {'ts': 1});
      final t = Uint8List.fromList(env.payload.tag);
      t[0] ^= 0x01;
      final bad = Envelope(
        type: env.type,
        payload: EncryptedPayload(
          nonce: env.payload.nonce,
          ciphertext: env.payload.ciphertext,
          tag: t,
        ),
      );
      expect(
        () => SecureSession(key: key).open(bad),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('重放同一消息被拒绝（nonce 缓存）', () {
      final a = SecureSession(key: key);
      final b = SecureSession(key: key);
      final env = a.seal(MsgType.notePush, {'content': 'once'});
      expect(b.open(env)['content'], 'once');
      // 原样重放
      expect(
        () => b.open(env),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('重放即使换 type 字段也被拒（nonce 才是依据）', () {
      final a = SecureSession(key: key);
      final b = SecureSession(key: key);
      final env = a.seal(MsgType.notePush, {'content': 'once'});
      b.open(env);
      final relayed = Envelope(type: MsgType.ping, payload: env.payload);
      expect(() => b.open(relayed), throwsA(isA<EnvelopeException>()));
    });

    test('篡改消息不会被当作新 nonce 接受', () {
      final a = SecureSession(key: key);
      final b = SecureSession(key: key);
      final env = a.seal(MsgType.notePush, {'content': 'x'});
      final ct = Uint8List.fromList(env.payload.ciphertext);
      ct[0] ^= 0x01;
      final bad = Envelope(
        type: env.type,
        payload: EncryptedPayload(
          nonce: env.payload.nonce,
          ciphertext: ct,
          tag: env.payload.tag,
        ),
      );
      expect(() => b.open(bad), throwsA(isA<EnvelopeException>()));
      // 且不应污染 nonce 缓存，原消息仍可正常接收
      expect(b.open(env)['content'], 'x');
    });

    test('批量消息全部可解且各不相同', () {
      final a = SecureSession(key: key);
      final b = SecureSession(key: key);
      for (var i = 0; i < 150; i++) {
        expect(b.open(a.seal(MsgType.ping, {'ts': i}))['ts'], i);
      }
    });
  });

  group('NonceCache 容量与淘汰', () {
    test('默认容量 200 且与协议一致', () {
      expect(NonceCache().capacity, ProtocolConst.nonceCacheSize);
      expect(NonceCache().capacity, 200);
    });

    test('重复 nonce 第一次 true、第二次 false', () {
      final c = NonceCache();
      final n = Uint8List.fromList(List<int>.generate(12, (i) => i));
      expect(c.checkAndStore(n), isTrue);
      expect(c.checkAndStore(n), isFalse);
    });

    test('容量满后淘汰最旧：超过 200 条仍只保留 200', () {
      final c = NonceCache();
      for (var i = 0; i < 250; i++) {
        expect(
          c.checkAndStore(Uint8List.fromList(List<int>.filled(12, i % 256)..[0] = i & 0xff)),
          isTrue,
        );
      }
      expect(c.length, 200);
    });

    test('被淘汰的旧 nonce 再次出现时视为新消息（滑动窗口语义）', () {
      final c = NonceCache(capacity: 3);
      final n1 = Uint8List.fromList([1, 1, 1]);
      expect(c.checkAndStore(n1), isTrue);
      for (var i = 0; i < 3; i++) {
        c.checkAndStore(Uint8List.fromList([9, 9, i]));
      }
      expect(c.contains(n1), isFalse);
      expect(c.checkAndStore(n1), isTrue);
    });

    test('clear 后全部遗忘', () {
      final c = NonceCache();
      final n = Uint8List.fromList([5, 5, 5]);
      c.checkAndStore(n);
      c.clear();
      expect(c.checkAndStore(n), isTrue);
    });
  });
}
