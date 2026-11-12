import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

NoteMeta n(
  String id, {
  required String content,
  required Map<String, int> vv,
  String? hash,
  bool deleted = false,
  int ts = 1000,
  String title = 'T',
}) {
  final h = hash ?? 'hash-$id-$vv-$content';
  return NoteMeta(
    noteId: id,
    title: title,
    content: content,
    versionVector: VersionVector(vv),
    contentHash: h,
    createdAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
    isDeleted: deleted,
  );
}

void main() {
  final devA = 'dev-a';
  final devB = 'dev-b';

  group('版本向量分类（变更 6.1 / 6.3）', () {
    test('equal 且 hash 同 → skip', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: 'c', vv: {devA: 1}, hash: 'H')},
        remote: {'x': n('x', content: 'c', vv: {devA: 1}, hash: 'H')},
      );
      expect(d.single.action, SyncAction.skip);
    });

    test('dominates（本地新）且对端未动 → patch', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: 'c2', vv: {devA: 2}, hash: 'H2')},
        remote: {'x': n('x', content: 'c1', vv: {devA: 1}, hash: 'H1')},
        baselines: {'x': VersionVector({devA: 1})},
      );
      expect(d.single.action, SyncAction.patch);
      expect(d.single.relation, VersionRelation.dominates);
    });

    test('dominates 但对端已动（版本超出基线）→ 全量 push', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: 'c3', vv: {devA: 2, devB: 1}, hash: 'H3')},
        remote: {'x': n('x', content: 'c2', vv: {devA: 1, devB: 1}, hash: 'H2')},
        baselines: {'x': VersionVector({devA: 1})},
      );
      expect(d.single.action, SyncAction.push);
    });

    test('dominated（对端新）→ pull', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: 'c1', vv: {devA: 1}, hash: 'H1')},
        remote: {'x': n('x', content: 'c2', vv: {devA: 2}, hash: 'H2')},
      );
      expect(d.single.action, SyncAction.pull);
    });

    test('concurrent → conflict（不覆盖）', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: 'A 改', vv: {devA: 2, devB: 1}, hash: 'HA')},
        remote: {'x': n('x', content: 'B 改', vv: {devA: 1, devB: 2}, hash: 'HB')},
      );
      expect(d.single.action, SyncAction.conflict);
      expect(d.single.relation, VersionRelation.concurrent);
    });

    test('无基线时 dominates → 保守走全量 push（不发 patch）', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: 'c2', vv: {devA: 2})},
        remote: {'x': n('x', content: 'c1', vv: {devA: 1})},
      );
      expect(d.single.action, SyncAction.push);
    });
  });

  group('块级差异同步阈值（变更 6.3 / 验收项）', () {
    test('≥256KB 且本地新 → blockSync', () {
      final big = 'a' * (256 * 1024);
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: big, vv: {devA: 2}, hash: 'H2')},
        remote: {'x': n('x', content: 'small', vv: {devA: 1}, hash: 'H1')},
        baselines: {'x': VersionVector({devA: 1})},
      );
      expect(d.single.action, SyncAction.blockSync);
    });

    test('略小于 256KB 仍走 patch', () {
      final just = 'a' * (256 * 1024 - 1);
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: just, vv: {devA: 2}, hash: 'H2')},
        remote: {'x': n('x', content: 's', vv: {devA: 1}, hash: 'H1')},
        baselines: {'x': VersionVector({devA: 1})},
      );
      expect(d.single.action, SyncAction.patch);
    });

    test('阈值常量与文档一致', () {
      expect(SyncPlanner.blockSyncThresholdBytes, 256 * 1024);
    });

    test('中文按 UTF-8 字节数计算（3 字节/字）', () {
      expect(SyncPlanner.byteLength('中'), 3);
      expect(SyncPlanner.byteLength('a'), 1);
      expect(SyncPlanner.byteLength('中a'), 4);
      expect(SyncPlanner.byteLength('🎉'), 4);
    });

    test('中文大文档也能正确判定为块级', () {
      final cn = '中' * (100 * 1024); // 约 300KB
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: cn, vv: {devA: 2}, hash: 'H2')},
        remote: {'x': n('x', content: '短', vv: {devA: 1}, hash: 'H1')},
        baselines: {'x': VersionVector({devA: 1})},
      );
      expect(d.single.action, SyncAction.blockSync);
    });
  });

  group('删除传播', () {
    test('本地删除且更新 → pushDelete', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: '', vv: {devA: 2}, deleted: true)},
        remote: {'x': n('x', content: 'c', vv: {devA: 1})},
      );
      expect(d.single.action, SyncAction.pushDelete);
    });

    test('本地删除但对端并发编辑 → conflict（保留证据，不静默删）', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: '', vv: {devA: 2, devB: 1}, deleted: true)},
        remote: {'x': n('x', content: 'B 还在写', vv: {devA: 1, devB: 2})},
      );
      expect(d.single.action, SyncAction.conflict);
    });

    test('对端删除而本地从未见过 → 不拉墓碑', () {
      final d = SyncPlanner.plan(
        local: {},
        remote: {'x': n('x', content: '', vv: {devA: 1}, deleted: true)},
      );
      expect(d, isEmpty);
    });

    test('双方同版本同 hash 且都删除 → skip', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: '', vv: {devA: 1}, hash: 'H', deleted: true)},
        remote: {'x': n('x', content: '', vv: {devA: 1}, hash: 'H', deleted: true)},
      );
      expect(d.single.action, SyncAction.skip);
    });

    test('同版本但删除状态冲突 → 收敛到未删除，两端方向相反但状态一致', () {
      final alive = n('x', content: 'c', vv: {devA: 1}, hash: 'H');
      final dead = n('x', content: 'c', vv: {devA: 1}, hash: 'H', deleted: true);

      final d1 = SyncPlanner.plan(local: {'x': dead}, remote: {'x': alive});
      final d2 = SyncPlanner.plan(local: {'x': alive}, remote: {'x': dead});

      expect(d1.single.action, SyncAction.pull);
      expect(d2.single.action, SyncAction.push);
    });

    test('同版本但 hash 不同 → updatedAt 兜底', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: 'c1', vv: {devA: 1}, hash: 'H1', ts: 2000)},
        remote: {'x': n('x', content: 'c2', vv: {devA: 1}, hash: 'H2', ts: 1000)},
      );
      expect(d.single.action, SyncAction.push);
      expect(d.single.reason, contains('兜底'));
    });
  });

  group('单向存在', () {
    test('对端有本地无 → pull', () {
      final d = SyncPlanner.plan(
        local: {},
        remote: {'x': n('x', content: 'c', vv: {devA: 1})},
      );
      expect(d.single.action, SyncAction.pull);
    });

    test('本地有对端无 → push', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: 'c', vv: {devA: 1})},
        remote: {},
      );
      expect(d.single.action, SyncAction.push);
    });

    test('本地有对端无且已删除 → pushDelete', () {
      final d = SyncPlanner.plan(
        local: {'x': n('x', content: '', vv: {devA: 1}, deleted: true)},
        remote: {},
      );
      expect(d.single.action, SyncAction.pushDelete);
    });
  });

  group('冲突解决：保留两份（变更 6.1 / 验收项）', () {
    test('较新者占原 noteId', () {
      final older = n('x', content: '旧', vv: {devA: 1}, ts: 1000);
      final newer = n('x', content: '新', vv: {devB: 1}, ts: 2000);
      final r = SyncPlanner.resolveConflict(older, newer);
      expect(r.winner.content, '新');
      expect(r.loser.content, '旧');
    });

    test('传入顺序不影响结果', () {
      final older = n('x', content: '旧', vv: {devA: 1}, ts: 1000);
      final newer = n('x', content: '新', vv: {devB: 1}, ts: 2000);
      expect(SyncPlanner.resolveConflict(older, newer).winner.content, '新');
      expect(SyncPlanner.resolveConflict(newer, older).winner.content, '新');
    });

    test('时间戳相同 → 按 contentHash 确定性打破平局', () {
      final a = n('x', content: 'A', vv: {devA: 1}, hash: 'AAA', ts: 1000);
      final b = n('x', content: 'B', vv: {devB: 1}, hash: 'ZZZ', ts: 1000);
      // 两端调用必须得到同一个胜者
      expect(
        SyncPlanner.resolveConflict(a, b).winner.content,
        SyncPlanner.resolveConflict(b, a).winner.content,
      );
    });

    test('两份内容都保留（loser 可另存为冲突副本）', () {
      final older = n('x', content: '用户的旧内容', vv: {devA: 1}, ts: 1000);
      final newer = n('x', content: '用户的新内容', vv: {devB: 1}, ts: 2000);
      final r = SyncPlanner.resolveConflict(older, newer);
      final kept = {r.winner.content, r.loser.content};
      expect(kept, {'用户的旧内容', '用户的新内容'});
    });

    test('冲突副本标题后缀常量存在', () {
      expect(conflictTitleSuffix, isNotEmpty);
    });
  });

  group('patch 体积约束（变更 6.4）', () {
    test('比例为 0.7', () {
      expect(SyncPlanner.patchSizeRatioLimit, 0.7);
    });
  });

  group('多笔记整体规划', () {
    test('混合场景产出正确动作集合', () {
      final decisions = SyncPlanner.plan(
        local: {
          'skip_me': n('skip_me', content: 'c', vv: {devA: 1}, hash: 'H'),
          'pull_me': n('pull_me', content: 'c', vv: {devA: 1}),
          'patch_me': n('patch_me', content: 'c2', vv: {devA: 2}),
          'only_local': n('only_local', content: 'c', vv: {devA: 1}),
        },
        remote: {
          'skip_me': n('skip_me', content: 'c', vv: {devA: 1}, hash: 'H'),
          'pull_me': n('pull_me', content: 'c', vv: {devA: 2}),
          'patch_me': n('patch_me', content: 'c1', vv: {devA: 1}),
          'only_remote': n('only_remote', content: 'c', vv: {devA: 1}),
        },
        baselines: {'patch_me': VersionVector({devA: 1})},
      );
      final byId = {for (final d in decisions) d.noteId: d.action};

      expect(byId['skip_me'], SyncAction.skip);
      expect(byId['pull_me'], SyncAction.pull);
      expect(byId['patch_me'], SyncAction.patch);
      expect(byId['only_local'], SyncAction.push);
      expect(byId['only_remote'], SyncAction.pull);
    });

    test('空对空 → 无动作', () {
      expect(SyncPlanner.plan(local: {}, remote: {}), isEmpty);
    });

    test('结果按 noteId 排序（确定性）', () {
      final d = SyncPlanner.plan(
        local: {
          'c': n('c', content: 'x', vv: {devA: 1}),
          'a': n('a', content: 'x', vv: {devA: 1}),
          'b': n('b', content: 'x', vv: {devA: 1}),
        },
        remote: {},
      );
      expect(d.map((x) => x.noteId).toList(), ['a', 'b', 'c']);
    });

    test('规划双向对称：我 patch 的正是对方 pull 的', () {
      final local = {'x': n('x', content: 'c2', vv: {devA: 2})};
      final remote = {'x': n('x', content: 'c1', vv: {devA: 1})};
      expect(
        SyncPlanner.plan(local: local, remote: remote).single.action,
        SyncAction.push,
      );
      expect(
        SyncPlanner.plan(local: remote, remote: local).single.action,
        SyncAction.pull,
      );
    });
  });

  group('图片同步规划（第一版逻辑不变）', () {
    test('missingImages 返回该推送的哈希', () {
      expect(
        SyncPlanner.missingImages(peerHashes: {'a', 'b'}, localHashes: {'b', 'c'}),
        {'c'},
      );
    });

    test('对端已全有 → 空集', () {
      expect(
        SyncPlanner.missingImages(peerHashes: {'a', 'b'}, localHashes: {'a'}),
        isEmpty,
      );
    });
  });
}
