import 'dart:convert';
import 'dart:typed_data';

import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

void main() {
  const masterKey = 'AAAAAAAABBBBBBBBCCCCCCCC';
  const deviceId = 'dev-b-uuid';
  const deviceName = '手机 B';
  final now = DateTime.fromMillisecondsSinceEpoch(1234567890000, isUtc: true);
  final nowMillis = now.millisecondsSinceEpoch;

  String codeAt(DateTime t) => PairingHandshake.currentCode(masterKey, now: t);

  /// 构造一个合法的明文 pair_request。
  PairRequest req({
    required String code,
    int? clientTime,
    Uint8List? nonce,
    String devId = deviceId,
    String devName = deviceName,
  }) =>
      PairingHandshake.buildRequest(
        code: code,
        deviceId: devId,
        deviceName: devName,
        clientTime: clientTime ?? nowMillis,
        nonce: nonce,
      );

  PairingAttempt verify(PairRequest r, {NonceCache? cache}) =>
      PairingHandshake.verifyRequest(
        request: r,
        masterKey: masterKey,
        nowMillis: nowMillis,
        nonceCache: cache,
      );

  group('配对本正确性', () {
    test('正确的码 → 校验通过', () {
      final a = verify(req(code: codeAt(now)));
      expect(a.isOk, isTrue);
      expect(a.matchedCode, codeAt(now));
      expect(a.key, equals(Kdf.pairKey(codeAt(now))));
    });

    test('错误的码 → 拒绝', () {
      final a = verify(req(code: '000000'));
      expect(a.isOk, isFalse);
      expect(a.status, PairingHandshake.badCode);
    });

    test('另一个 masterKey 的码 → 拒绝', () {
      final a = verify(req(code: PairingHandshake.currentCode('ZZZZZZZZZZZZZZZZZZZZZZ', now: now)));
      expect(a.isOk, isFalse);
    });

    test('窗口 ±1：慢一步的码通过', () {
      final a = verify(req(
        code: codeAt(now.subtract(const Duration(seconds: 30))),
        clientTime: nowMillis - 30000,
      ));
      expect(a.isOk, isTrue);
    });

    test('窗口 ±1：快一步的码通过', () {
      final a = verify(req(
        code: codeAt(now.add(const Duration(seconds: 30))),
        clientTime: nowMillis + 30000,
      ));
      expect(a.isOk, isTrue);
    });

    test('超出窗口（±90s）的码 → 拒绝', () {
      final a = verify(req(
        code: codeAt(now.subtract(const Duration(seconds: 90))),
        clientTime: nowMillis - 90000,
      ));
      expect(a.isOk, isFalse);
    });

    test('clientTime 偏差超 60s → badTime', () {
      final a = verify(req(code: codeAt(now), clientTime: nowMillis + 120000));
      expect(a.status, PairingHandshake.badTime);
    });
  });

  group('变更 5 验收项：载荷与安全', () {
    test('pair_request 中无明文 6 位码', () {
      final code = codeAt(now);
      final json = req(code: code).encode();
      // 码不得以明文出现
      expect(json.contains(code), isFalse);
      // 也不得出现 code 字段名
      expect(json.contains('"code"'), isFalse);
    });

    test('载荷字段与文档一致', () {
      final j = req(code: codeAt(now)).toJson();
      expect(j.keys.toSet(), {'type', 'clientTime', 'nonce', 'deviceId', 'deviceName', 'hmac'});
      expect(j['type'], 'pair_request');
    });

    test('nonce 为 16 字节', () {
      final j = req(code: codeAt(now)).toJson();
      expect(base64.decode(j['nonce'] as String).length, 16);
    });

    test('HMAC 输入串格式为 clientTime|nonce|deviceId|deviceName', () {
      final r = req(code: codeAt(now));
      expect(
        PairingHandshake.hmacMessage(
          clientTime: r.clientTime,
          nonceB64: r.nonceB64,
          deviceId: r.deviceId,
          deviceName: r.deviceName,
        ),
        '${r.clientTime}|${r.nonceB64}|$deviceId|$deviceName',
      );
    });

    test('错误 code 构造的 HMAC → 拒绝（且不泄露"接近了"）', () {
      final a = verify(req(code: '123456')); // 大概率错
      expect(a.isOk, isFalse);
      expect(a.status, PairingHandshake.badCode);
      // 失败结果不含任何部分匹配信息
      expect(a.matchedCode, isNull);
      expect(a.key, isNull);
    });

    test('重放同一 pair_request → 拒绝', () {
      final cache = NonceCache();
      final r = req(code: codeAt(now));
      expect(verify(r, cache: cache).isOk, isTrue);
      final second = verify(r, cache: cache);
      expect(second.isOk, isFalse);
      expect(second.status, PairingHandshake.replayed);
    });

    test('不同 nonce 的两次请求都能通过（不是一次性锁死）', () {
      final cache = NonceCache();
      expect(verify(req(code: codeAt(now)), cache: cache).isOk, isTrue);
      expect(verify(req(code: codeAt(now)), cache: cache).isOk, isTrue);
    });

    test('篡改 hmac → 拒绝', () {
      final r = req(code: codeAt(now));
      final tampered = PairRequest(
        clientTime: r.clientTime,
        nonceB64: r.nonceB64,
        deviceId: r.deviceId,
        deviceName: r.deviceName,
        hmac: base64.encode(Uint8List(32)),
      );
      expect(verify(tampered).isOk, isFalse);
    });

    test('篡改 deviceId（HMAC 未同步更新）→ 拒绝', () {
      final r = req(code: codeAt(now));
      final tampered = PairRequest(
        clientTime: r.clientTime,
        nonceB64: r.nonceB64,
        deviceId: 'attacker-device',
        deviceName: r.deviceName,
        hmac: r.hmac,
      );
      expect(verify(tampered).isOk, isFalse);
    });

    test('篡改 deviceName → 拒绝', () {
      final r = req(code: codeAt(now));
      final tampered = PairRequest(
        clientTime: r.clientTime,
        nonceB64: r.nonceB64,
        deviceId: r.deviceId,
        deviceName: '假名字',
        hmac: r.hmac,
      );
      expect(verify(tampered).isOk, isFalse);
    });

    test('篡改 clientTime → 拒绝或判为 badTime', () {
      final r = req(code: codeAt(now));
      final tampered = PairRequest(
        clientTime: r.clientTime + 1000,
        nonceB64: r.nonceB64,
        deviceId: r.deviceId,
        deviceName: r.deviceName,
        hmac: r.hmac,
      );
      final a = verify(tampered);
      expect(a.isOk, isFalse);
    });

    test('base64 非法的 hmac → 拒绝而不抛异常', () {
      final r = req(code: codeAt(now));
      final bad = PairRequest(
        clientTime: r.clientTime,
        nonceB64: r.nonceB64,
        deviceId: r.deviceId,
        deviceName: r.deviceName,
        hmac: '!!!not-base64!!!',
      );
      expect(verify(bad).isOk, isFalse);
    });
  });

  group('恒定时间比较（变更 9 验收项）', () {
    test('相等返回 true，不等返回 false', () {
      final a = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final b = Uint8List.fromList(List<int>.generate(32, (i) => i));
      expect(Hashing.constantTimeEquals(a, b), isTrue);
      b[31] ^= 1;
      expect(Hashing.constantTimeEquals(a, b), isFalse);
    });

    test('长度不同返回 false 且不越界', () {
      expect(
        Hashing.constantTimeEquals(Uint8List(31), Uint8List(32)),
        isFalse,
      );
    });

    test('全部字节都参与比较（首字节差异也能检出）', () {
      final a = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final b = Uint8List.fromList(List<int>.generate(32, (i) => i));
      b[0] ^= 0xff;
      expect(Hashing.constantTimeEquals(a, b), isFalse);
    });

    test('base64 版本：非法输入返回 false 而不抛异常', () {
      expect(Hashing.constantTimeEqualsB64('abc', '!!!'), isFalse);
    });

    test('HMAC 比较路径使用恒定时间函数（行为一致性检查）', () {
      // 无论差异在第一位还是最后一位，结果都必须是 false，
      // 且不因位置不同而走不同分支。
      final key = Kdf.pairKey('123456');
      final msg = utf8.encode('m');
      final good = Hashing.hmacSha256(key, msg);
      for (final pos in <int>[0, 15, 31]) {
        final bad = Uint8List.fromList(good)..[pos] ^= 0x01;
        expect(Hashing.constantTimeEquals(good, bad), isFalse);
      }
    });
  });

  group('pair_success 回传 masterKey', () {
    test('客户端用命中码派生的密钥能取回 masterKey', () {
      final code = codeAt(now);
      final a = verify(req(code: code));
      final success = PairingHandshake.buildSuccess(
        handshakeKey: a.key!,
        masterKey: masterKey,
      );
      expect(
        PairingHandshake.openSuccess(
          handshakeKey: Kdf.pairKey(code),
          envelope: success,
        ),
        masterKey,
      );
    });

    test('错误密钥无法取回', () {
      final success = PairingHandshake.buildSuccess(
        handshakeKey: Kdf.pairKey(codeAt(now)),
        masterKey: masterKey,
      );
      expect(
        PairingHandshake.openSuccess(
          handshakeKey: Kdf.pairKey('999999'),
          envelope: success,
        ),
        isNull,
      );
    });

    test('pair_success 信封内无 masterKey 明文', () {
      final success = PairingHandshake.buildSuccess(
        handshakeKey: Kdf.pairKey(codeAt(now)),
        masterKey: masterKey,
      );
      expect(success.encode().contains(masterKey), isFalse);
    });
  });

  group('pair_fail 为明文', () {
    test('只有 type 与 reason', () {
      final f = PairingHandshake.buildFailure('配对码错误');
      expect(f.keys.toSet(), {'type', 'reason'});
      expect(f['type'], 'pair_fail');
      expect(f['reason'], '配对码错误');
    });
  });

  group('PairRequest 编解码', () {
    test('JSON 往返', () {
      final r = req(code: codeAt(now));
      final back = PairRequest.fromJson(jsonDecode(r.encode()) as Map<String, dynamic>);
      expect(back, isNotNull);
      expect(back!.clientTime, r.clientTime);
      expect(back.nonceB64, r.nonceB64);
      expect(back.deviceId, r.deviceId);
      expect(back.deviceName, r.deviceName);
      expect(back.hmac, r.hmac);
    });

    test('字段缺失返回 null', () {
      expect(PairRequest.fromJson(<String, dynamic>{}), isNull);
      expect(PairRequest.fromJson(<String, dynamic>{'clientTime': 'x'}), isNull);
    });

    test('clientTime 类型不对返回 null', () {
      final j = req(code: codeAt(now)).toJson()..['clientTime'] = 'not-int';
      expect(PairRequest.fromJson(j), isNull);
    });
  });
}
