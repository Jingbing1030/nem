import 'dart:convert';
import 'dart:typed_data';

import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

/// 两设备端到端联调（纯逻辑层）。
///
/// 用真实的加密信封、真实的配对握手、真实的同步规划器，把「两台设备
/// 通过 WS 交换消息」的过程在内存里跑一遍。这覆盖了无法在容器内做真机
/// 联调时最关键的协议正确性；真机层（socket / mDNS / UI）另由人工核查。
class FakeWs {
  FakeWs(this.name);

  final String name;
  final List<String> wire = <String>[];

  /// 记录发出的原始字节（用于断言「线上没有明文机密」）。
  void send(String encoded) => wire.add(encoded);
}

void main() {
  group('首次配对全流程（HMAC 版）', () {
    test('B 用 A 显示的码配对 → 拿到 masterKey → 双方能通会话消息', () {
      // A 是主机：已有 masterKey
      final aMasterKey = Kdf.generateMasterKey();
      final aWire = FakeWs('A');
      final bWire = FakeWs('B');

      // A 显示配对码（6 位 TOTP）
      final code = PairingHandshake.currentCode(aMasterKey);
      expect(RegExp(r'^\d{6}$').hasMatch(code), isTrue);

      // ---- B 发 pair_request（明文，含 HMAC 证明）----
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      final req = PairingHandshake.buildRequest(
        code: code,
        deviceId: 'device-b-uuid',
        deviceName: 'B 的手机',
        clientTime: nowMs,
      );
      bWire.send(req.encode());

      // 断言：线上没有明文码
      expect(aWire.wire.join() + bWire.wire.join(), isNot(contains('"code"')));
      for (final w in bWire.wire) {
        expect(w.contains(code), isFalse, reason: 'pair_request 泄漏了配对码');
      }

      // ---- A 校验 ----
      final nonceCache = NonceCache();
      final attempt = PairingHandshake.verifyRequest(
        request: req,
        masterKey: aMasterKey,
        nowMillis: nowMs,
        nonceCache: nonceCache,
      );
      expect(attempt.isOk, isTrue, reason: 'A 应接受正确的配对码');

      // ---- A 回 pair_success（用命中码派生的密钥加密 masterKey）----
      final success = PairingHandshake.buildSuccess(
        handshakeKey: attempt.key!,
        masterKey: aMasterKey,
      );
      aWire.send(success.encode());

      // ---- B 解开，拿到 masterKey ----
      final bHandshakeKey = Kdf.pairKey(code);
      final gotMasterKey = PairingHandshake.openSuccess(
        handshakeKey: bHandshakeKey,
        envelope: success,
      );
      expect(gotMasterKey, aMasterKey);
      // 断言：masterKey 不以明文上线
      expect(aWire.wire.join().contains(aMasterKey), isFalse);

      // ---- 双方切到会话密钥，互发业务消息 ----
      final sessionKey = Kdf.sessionKey(gotMasterKey!);
      final aSession = SecureSession(key: sessionKey);
      final bSession = SecureSession(key: sessionKey);

      final toB = aSession.seal(MsgType.notePush, <String, dynamic>{
        'noteId': 'n1',
        'content': '# 从 A 同步过来的笔记\n\n正文',
        'versionVector': <String, int>{'device-a': 1},
        'contentHash': 'H1',
        'updatedAt': nowMs,
        'imageHashes': <String>[],
      });
      final body = bSession.open(toB);
      expect(body['content'], contains('从 A 同步过来的笔记'));

      // B 回一条
      final toA = bSession.seal(MsgType.notePatchAck, <String, dynamic>{'noteId': 'n1'});
      expect(aSession.open(toA)['noteId'], 'n1');
    });

    test('错误配对码 → 拒绝（且不泄漏任何信息）', () {
      final masterKey = Kdf.generateMasterKey();
      final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;

      final good = PairingHandshake.currentCode(masterKey);
      var bad = '000000';
      if (bad == good) bad = '111111';

      final req = PairingHandshake.buildRequest(
        code: bad,
        deviceId: 'dev-b',
        deviceName: 'B',
        clientTime: nowMs,
      );

      final attempt = PairingHandshake.verifyRequest(
        request: req,
        masterKey: masterKey,
        nowMillis: nowMs,
      );
      expect(attempt.isOk, isFalse);
      expect(attempt.status, PairingHandshake.badCode);
      expect(attempt.key, isNull);
    });

    test('已配对设备重连（fast_auth）：能解密即认证', () {
      final masterKey = Kdf.generateMasterKey();
      final sessionKey = Kdf.sessionKey(masterKey);

      // B 发 fast_auth（会话密钥加密）
      final auth = SecureSession(key: sessionKey)
          .seal(MsgType.fastAuth, <String, dynamic>{'deviceId': 'device-b-uuid'});

      // A 用小会密钥解 —— 成功即认证通过
      final decoded =
          SecureSession(key: sessionKey).openOrNull(auth);
      expect(decoded, isNotNull);
      expect(decoded!['deviceId'], 'device-b-uuid');

      // 换错密钥（模拟未配对设备）→ 解不开
      final wrongKey = Kdf.sessionKey(Kdf.generateMasterKey());
      expect(SecureSession(key: wrongKey).openOrNull(auth), isNull);
    });

    test('密钥重置后，旧会话密钥失效（需重新配对）', () {
      final oldKey = Kdf.sessionKey(Kdf.generateMasterKey());
      final newMaster = Kdf.generateMasterKey();
      final newKey = Kdf.sessionKey(newMaster);

      final msg = SecureSession(key: oldKey)
          .seal(MsgType.fastAuth, <String, dynamic>{'deviceId': 'b'});

      // 重置后 A 用新密钥解 —— 必须失败
      expect(SecureSession(key: newKey).openOrNull(msg), isNull);
    });
  });

  group('同步一轮全流程（版本向量 + patch + 冲突副本）', () {
    NoteMeta note(
      String id,
      String content,
      Map<String, int> vv, {
      int ts = 1000,
      bool del = false,
      String title = '标题',
    }) =>
        NoteMeta(
          noteId: id,
          title: title,
          content: content,
          versionVector: VersionVector(vv),
          contentHash: Hashing.contentHash(content),
          createdAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
          isDeleted: del,
        );

    test('A 更新、B 未动 → 走 patch，且 patch 能正确应用', () {
      const devA = 'device-a';
      final baseText = List<String>.generate(100, (i) => '第 $i 行').join('\n');
      final newText = List<String>.generate(100, (i) => '第 $i 行').join('\n')
          .replaceFirst('第 5 行', '第 5 行（改过）');

      final decision = SyncPlanner.plan(
        local: {'n1': note('n1', newText, {devA: 2})},
        remote: {'n1': note('n1', baseText, {devA: 1})},
        baselines: {'n1': VersionVector({devA: 1})},
      ).single;

      expect(decision.action, SyncAction.patch);

      // 模拟传输 patch 并应用
      final patch = PatchUtil.makePatch(baseText, newText);
      expect(PatchUtil.applyPatch(baseText, patch), newText);
    });

    test('双方并发编辑 → conflict，两份内容都保留', () {
      const devA = 'device-a';
      const devB = 'device-b';

      final aNote = note('n1', 'A 的版本', {devA: 2, devB: 1}, ts: 2000);
      final bNote = note('n1', 'B 的版本', {devA: 1, devB: 2}, ts: 2001);

      final decision = SyncPlanner.plan(
        local: {'n1': aNote},
        remote: {'n1': bNote},
      ).single;
      expect(decision.action, SyncAction.conflict);

      final res = SyncPlanner.resolveConflict(aNote, bNote);
      // 胜者占原 noteId
      expect(res.winner.noteId, 'n1');
      // 两份内容都在（一份进原 id，一份进副本）
      expect(
        {res.winner.content, res.loser.content},
        {'A 的版本', 'B 的版本'},
      );
      // 败者需要新的 noteId + 标题后缀（由调用方分配）
      expect(conflictTitleSuffix, isNotEmpty);
    });

    test('删除传播：A 删除 → B 收到 pushDelete', () {
      const devA = 'device-a';
      final decision = SyncPlanner.plan(
        local: {'n1': note('n1', '', {devA: 2}, del: true)},
        remote: {'n1': note('n1', '原有内容', {devA: 1})},
      ).single;
      expect(decision.action, SyncAction.pushDelete);
    });

    test('图片清单对比：只请求本地缺失的哈希', () {
      final localHashes = <String>{'h1', 'h2'};
      final peerHashes = <String>{'h2', 'h3'};
      // 我缺 h3 → 请求它
      expect(peerHashes.difference(localHashes), {'h3'});
      // 对端缺 h1 → 我推送它
      expect(
        SyncPlanner.missingImages(peerHashes: peerHashes, localHashes: localHashes),
        {'h1'},
      );
    });

    test('图片分块传输 + SHA-256 校验（模拟一次完整图片同步）', () {
      // 造一张 >128KB 的“图片”
      final imageBytes = Uint8List.fromList(
        List<int>.generate(300 * 1024, (i) => (i * 31) & 0xff),
      );
      final hash = Hashing.sha256Hex(imageBytes);

      // 发送端分块
      const chunkSize = ProtocolConst.imageChunkSize;
      final total = (imageBytes.length / chunkSize).ceil();
      expect(total, greaterThan(1), reason: '应产生多个分块');

      final chunks = <int, Uint8List>{};
      for (var seq = 0; seq < total; seq++) {
        final start = seq * chunkSize;
        final end = (start + chunkSize).clamp(0, imageBytes.length);
        // 走 JSON 线格式（base64）
        final wire = jsonEncode(<String, dynamic>{
          'hash': hash,
          'seq': seq,
          'total': total,
          'data': base64.encode(imageBytes.sublist(start, end)),
        });
        final decoded = jsonDecode(wire) as Map<String, dynamic>;
        chunks[decoded['seq'] as int] =
            base64.decode(decoded['data'] as String);
      }

      // 接收端重组
      final builder = BytesBuilder();
      for (var i = 0; i < total; i++) {
        builder.add(chunks[i]!);
      }
      final reassembled = builder.takeBytes();

      // 校验：接收端算出的哈希必须与源端一致
      expect(Hashing.sha256Hex(reassembled), hash);
      expect(reassembled.length, imageBytes.length);
    });

    test('篡改的图片分块会被校验拒绝', () {
      final imageBytes = Uint8List.fromList(
        List<int>.generate(1000, (i) => i & 0xff),
      );
      final hash = Hashing.sha256Hex(imageBytes);

      // 篡改一个字节
      final tampered = Uint8List.fromList(imageBytes)..[0] ^= 0xFF;
      expect(Hashing.matchesSha256(tampered, hash), isFalse);
    });
  });

  group('协议安全：全流程中的攻击面', () {
    test('中间人篡改同步消息 → 接收端解密失败并应断开', () {
      final masterKey = Kdf.generateMasterKey();
      final key = Kdf.sessionKey(masterKey);

      final env = SecureSession(key: key).seal(MsgType.notePush, <String, dynamic>{
        'noteId': 'n1',
        'content': '机密内容',
      });

      // 攻击者翻转密文一位
      final tampered = Envelope(
        type: env.type,
        payload: EncryptedPayload(
          nonce: env.payload.nonce,
          ciphertext: Uint8List.fromList(env.payload.ciphertext)..[0] ^= 1,
          tag: env.payload.tag,
        ),
      );

      expect(
        () => SecureSession(key: key).open(tampered),
        throwsA(isA<EnvelopeException>()),
      );
    });

    test('重放已同步的消息 → 被 nonce 缓存拒绝', () {
      final key = Kdf.sessionKey(Kdf.generateMasterKey());
      final receiver = SecureSession(key: key);
      final env = SecureSession(key: key)
          .seal(MsgType.notePush, <String, dynamic>{'noteId': 'n1'});

      expect(receiver.open(env)['noteId'], 'n1');
      // 重放
      expect(() => receiver.open(env), throwsA(isA<EnvelopeException>()));
    });

    test('被动嗅探者拿不到任何明文（笔记内容 / 标题 / 设备名）', () {
      final key = Kdf.sessionKey(Kdf.generateMasterKey());
      const secretContent = '这是非常敏感的笔记正文';
      const secretTitle = '机密标题';

      final env = SecureSession(key: key).seal(MsgType.notePush, <String, dynamic>{
        'noteId': 'n1',
        'title': secretTitle,
        'content': secretContent,
      });
      final onWire = env.encode();

      expect(onWire.contains(secretContent), isFalse);
      expect(onWire.contains(secretTitle), isFalse);
      // 只能看到消息类型（协议设计如此，已在 PROTOCOL.md 说明）
      expect(onWire.contains(MsgType.notePush), isTrue);
    });
  });
}
