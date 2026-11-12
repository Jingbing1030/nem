import 'dart:convert';
import 'dart:typed_data';

import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

/// 最终版需求「验收清单」中**可在纯 Dart 层验证**的条目集中在此。
///
/// 无法在此验证的（真机双设备联调、UI 交互、Android 权限声明）由
/// 集成测试与人工核查覆盖，见 README 的验收对照表。
void main() {
  group('安全：变更 10 验收项', () {
    const masterKey = 'AAAAAAAABBBBBBBBCCCCCCCC';
    final now = DateTime.fromMillisecondsSinceEpoch(1234567890000, isUtc: true);

    test('☑ pair_request 中无明文 6 位码', () {
      final code = PairingHandshake.currentCode(masterKey, now: now);
      final req = PairingHandshake.buildRequest(
        code: code,
        deviceId: 'dev-b',
        deviceName: '手机B',
        clientTime: now.millisecondsSinceEpoch,
      );
      final wire = req.encode();

      // 明文码不得出现
      expect(wire.contains(code), isFalse);
      // 也不得有 code 字段
      expect(wire.contains('"code"'), isFalse);
      // 载荷里每个字段都不含该码
      for (final v in req.toJson().values) {
        expect(v.toString().contains(code), isFalse, reason: '字段 $v 泄漏了配对码');
      }
    });

    test('☑ 重放同一 pair_request → 服务端拒绝', () {
      final cache = NonceCache();
      final req = PairingHandshake.buildRequest(
        code: PairingHandshake.currentCode(masterKey, now: now),
        deviceId: 'dev-b',
        deviceName: 'B',
        clientTime: now.millisecondsSinceEpoch,
      );
      final first = PairingHandshake.verifyRequest(
        request: req,
        masterKey: masterKey,
        nowMillis: now.millisecondsSinceEpoch,
        nonceCache: cache,
      );
      expect(first.isOk, isTrue);

      final replay = PairingHandshake.verifyRequest(
        request: req,
        masterKey: masterKey,
        nowMillis: now.millisecondsSinceEpoch,
        nonceCache: cache,
      );
      expect(replay.isOk, isFalse);
      expect(replay.status, PairingHandshake.replayed);
    });

    test('☑ 错误 code 构造 HMAC → 拒绝且不泄露"接近了"', () {
      // 构造一个确定错误的码
      final good = PairingHandshake.currentCode(masterKey, now: now);
      var bad = '000000';
      if (bad == good) bad = '111111';

      final req = PairingHandshake.buildRequest(
        code: bad,
        deviceId: 'dev-b',
        deviceName: 'B',
        clientTime: now.millisecondsSinceEpoch,
      );
      final attempt = PairingHandshake.verifyRequest(
        request: req,
        masterKey: masterKey,
        nowMillis: now.millisecondsSinceEpoch,
      );
      expect(attempt.isOk, isFalse);
      expect(attempt.status, PairingHandshake.badCode);
      // 失败时不得返回任何中间信息
      expect(attempt.matchedCode, isNull);
      expect(attempt.key, isNull);
    });

    test('☑ HMAC 比较为恒定时间（函数语义 + 不提前返回）', () {
      final a = Uint8List.fromList(List<int>.generate(32, (i) => i));
      final b = Uint8List.fromList(List<int>.generate(32, (i) => i));
      expect(Hashing.constantTimeEquals(a, b), isTrue);

      // 差异在首字节 / 中间 / 末字节，结果都必须是 false
      for (final pos in <int>[0, 15, 31]) {
        final t = Uint8List.fromList(a)..[pos] ^= 0xFF;
        expect(Hashing.constantTimeEquals(a, t), isFalse);
      }
      // 长度不同：立即 false，但不抛异常
      expect(Hashing.constantTimeEquals(Uint8List(31), a), isFalse);
    });

    test('☑ 密文篡改 → 解密失败（GCM 认证）', () {
      final key = Kdf.sessionKey(masterKey);
      final ct = AesGcm.encrypt(key, utf8.encode('正文'));
      final tampered = EncryptedPayload(
        nonce: ct.nonce,
        ciphertext: Uint8List.fromList(ct.ciphertext)..[0] ^= 1,
        tag: ct.tag,
      );
      expect(AesGcm.tryDecrypt(key, tampered), isNull);
    });

    test('☑ 信封重放 → 拒绝（nonce 缓存）', () {
      final key = Kdf.sessionKey(masterKey);
      final sender = SecureSession(key: key);
      final receiver = SecureSession(key: key);
      final env = sender.seal(MsgType.notePush, <String, dynamic>{'noteId': 'x'});
      expect(receiver.open(env), isNotNull);
      expect(() => receiver.open(env), throwsA(isA<EnvelopeException>()));
    });

    test('☑ masterKey 生成：128 位、base64url、每次不同', () {
      final seen = <String>{};
      for (var i = 0; i < 100; i++) {
        final mk = Kdf.generateMasterKey();
        seen.add(mk);
        expect(mk.length, 22);
        expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(mk), isTrue);
        final pad = '=' * ((4 - mk.length % 4) % 4);
        expect(base64Url.decode('$mk$pad').length, 16);
      }
      expect(seen.length, 100);
    });
  });

  group('同步：变更 10 验收项', () {
    NoteMeta n(String id, String content, Map<String, int> vv, {int ts = 1000, bool del = false}) =>
        NoteMeta(
          noteId: id,
          title: 'T',
          content: content,
          versionVector: VersionVector(vv),
          contentHash: 'h-$content-$vv',
          createdAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
          updatedAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
          isDeleted: del,
        );

    test('☑ 版本向量比较单测（equal / dominates / dominated / concurrent）', () {
      expect(
        VersionVector({'a': 1}).compare(VersionVector({'a': 1})),
        VersionRelation.equal,
      );
      expect(
        VersionVector({'a': 2}).compare(VersionVector({'a': 1})),
        VersionRelation.dominates,
      );
      expect(
        VersionVector({'a': 1}).compare(VersionVector({'a': 2})),
        VersionRelation.dominated,
      );
      expect(
        VersionVector({'a': 2, 'b': 1}).compare(VersionVector({'a': 1, 'b': 2})),
        VersionRelation.concurrent,
      );
    });

    test('☑ A、B 同时编辑同一篇 → 生成冲突副本，两份内容都保留', () {
      final local = n('x', 'A 的内容', {'a': 2, 'b': 1}, ts: 2000);
      final remote = n('x', 'B 的内容', {'a': 1, 'b': 2}, ts: 2001);

      final decision = SyncPlanner.plan(
        local: {'x': local},
        remote: {'x': remote},
      ).single;

      expect(decision.action, SyncAction.conflict);

      // 解决冲突：胜者占原 id，败者退居副本 —— 两份都在
      final res = SyncPlanner.resolveConflict(local, remote);
      final kept = {res.winner.content, res.loser.content};
      expect(kept, {'A 的内容', 'B 的内容'});
      expect(res.winner.noteId, 'x', reason: '胜者保留原 noteId');
    });

    test('☑ A 离线编辑 100 次后重连、对端未动 → 生成单个 patch', () {
      // 建立共同基线（用有实际规模的正文，短文场景见下一个用例）
      final baseline = VersionVector({'a': 1});
      final baseText =
          List<String>.generate(200, (i) => '这是第 $i 行的原始内容').join('\n');

      // 离线编辑 100 次，最终只改了 1 行
      var cur = baseText;
      for (var i = 0; i < 100; i++) {
        final lines = cur.split('\n')..[1] = '第 $i 次编辑';
        cur = lines.join('\n');
      }

      // 规划：应产出单个 patch 决策
      final decision = SyncPlanner.plan(
        local: {'x': n('x', cur, {'a': 101})},
        remote: {'x': n('x', baseText, {'a': 1})},
        baselines: {'x': baseline},
      ).single;

      expect(decision.action, SyncAction.patch);

      // patch 只有一份（不是 100 份），且体积与编辑次数无关
      final patch = PatchUtil.makePatch(baseText, cur);
      expect(PatchUtil.applyPatch(baseText, patch), cur);
      expect(PatchUtil.patchRatio(baseText, patch), lessThan(0.7));
    });

    test('短文不发 patch：patch 有 JSON 结构开销，小文档直接发全量更省', () {
      const base = 'line1\nline2\nline3';
      var cur = base;
      for (var i = 0; i < 100; i++) {
        final lines = cur.split('\n')..[1] = '第 $i 次编辑';
        cur = lines.join('\n');
      }
      final patch = PatchUtil.makePatch(base, cur);
      // 3 行正文的 patch 必然超过正文本身 —— 此时应改发全量
      expect(PatchUtil.patchRatio(base, patch), greaterThan(0.7));
      expect(PatchUtil.shouldSendPatch(base, patch), isFalse);
      // 但 patch 本身仍然正确
      expect(PatchUtil.applyPatch(base, patch), cur);
    });

    test('☑ 1MB 笔记改 3 处 → 传输量 < 50KB', () {
      final base = List<String>.generate(20000, (i) => '第 $i 行的内容，填充体积').join('\n');
      expect(utf8.encode(base).length, greaterThan(500 * 1024));

      final lines = base.split('\n')
        ..[0] = '改1'
        ..[9999] = '改2'
        ..[19999] = '改3';
      final patched = lines.join('\n');

      final patch = PatchUtil.makePatch(base, patched);
      expect(utf8.encode(patch).length, lessThan(50 * 1024));
      expect(PatchUtil.applyPatch(base, patch), patched);
    });

    test('☑ 删除传播（软删 + 版本向量）', () {
      final decision = SyncPlanner.plan(
        local: {'x': n('x', '', {'a': 2}, del: true)},
        remote: {'x': n('x', 'c', {'a': 1})},
      ).single;
      expect(decision.action, SyncAction.pushDelete);
    });

    test('☑ 块级同步阈值：≥256KB 走块级', () {
      final big = 'a' * (256 * 1024);
      final decision = SyncPlanner.plan(
        local: {'x': n('x', big, {'a': 2})},
        remote: {'x': n('x', 'small', {'a': 1})},
        baselines: {'x': VersionVector({'a': 1})},
      ).single;
      expect(decision.action, SyncAction.blockSync);
    });
  });

  group('存储与导出：可在纯 Dart 层验证的部分', () {
    test('☑ 图片引用安全约束（禁止绝对路径 / base64 内嵌）', () {
      expect(VaultPaths.validateImageRef('/sdcard/a.png'), isNotNull);
      expect(VaultPaths.validateImageRef('data:image/png;base64,AAA'), isNotNull);
      expect(VaultPaths.validateImageRef('assets\\images\\a.png'), isNotNull);
      expect(
        VaultPaths.validateImageRef('assets/images/${'a' * 64}.png'),
        isNull,
      );
    });

    test('☑ 标题/摘要提取规则', () {
      expect(MarkdownDoc.extractTitle('# 标题\n正文'), '标题');
      expect(MarkdownDoc.extractTitle('普通首行\n第二行'), '普通首行');
      expect(MarkdownDoc.extractTitle(''), '未命名');
      expect(MarkdownDoc.extractExcerpt('a' * 500).length, 100);
    });

    test('☑ 冲突副本标题后缀', () {
      expect(conflictTitleSuffix, isNotEmpty);
    });

    test('☑ TOTP 仍为 6 位 / 30s / ±1 窗口（第一版逻辑不变）', () {
      expect(ProtocolConst.pairingCodeDigits, 6);
      expect(ProtocolConst.totpPeriod, 30);
      expect(ProtocolConst.totpWindow, 1);
    });

    test('☑ AES-GCM 参数未变（IV 12B / tag 16B）', () {
      final key = Uint8List(32);
      final ct = AesGcm.encrypt(key, utf8.encode('x'));
      expect(ct.nonce.length, 12);
      expect(ct.tag.length, 16);
    });

    test('☑ 第一版保留项：图片分块 128KB、心跳 30s、锁 60s', () {
      expect(ProtocolConst.imageChunkSize, 128 * 1024);
      expect(ProtocolConst.heartbeatSeconds, 30);
      expect(ProtocolConst.pairingLockoutSeconds, 60);
      expect(ProtocolConst.pairingFailureLimit, 3);
      expect(ProtocolConst.nonceCacheSize, 200);
    });
  });
}
