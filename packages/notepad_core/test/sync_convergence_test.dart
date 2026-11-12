import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

/// 模拟设备：持有 notes 与「与本对端的同步基线」。
class FakeDevice {
  FakeDevice(this.deviceId, Map<String, NoteMeta> initial)
      : notes = Map<String, NoteMeta>.from(initial);

  final String deviceId;
  final Map<String, NoteMeta> notes;

  /// 与本对端共享的基线（noteId → 上次同步时的版本向量）。
  final Map<String, VersionVector> baseline = <String, VersionVector>{};

  /// 本设备编辑一篇笔记：版本向量自增，返回新笔记。
  NoteMeta edit(String noteId, String content, {int ts = 0, bool? deleted}) {
    final cur = notes[noteId];
    final vv = (cur?.versionVector ?? VersionVector.empty()).increment(deviceId);
    final next = NoteMeta(
      noteId: noteId,
      title: cur?.title ?? 'T',
      content: content,
      versionVector: vv,
      contentHash: 'h-$content-$vv',
      createdAt: cur?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      isDeleted: deleted ?? cur?.isDeleted ?? false,
    );
    notes[noteId] = next;
    return next;
  }

  /// 与 [peer] 做一轮同步，返回本轮动作列表。
  List<SyncDecision> syncWith(FakeDevice peer, {List<String>? conflictIds}) {
    final decisions = SyncPlanner.plan(
      local: notes,
      remote: peer.notes,
      baselines: baseline,
    );

    for (final d in decisions) {
      final remoteNote = peer.notes[d.noteId];
      final localNote = notes[d.noteId];

      switch (d.action) {
        case SyncAction.skip:
          break;

        case SyncAction.pull:
          if (remoteNote != null) {
            notes[d.noteId] = remoteNote;
            baseline[d.noteId] = remoteNote.versionVector;
          }

        case SyncAction.push:
        case SyncAction.patch:
        case SyncAction.blockSync:
          if (localNote != null) {
            peer.notes[d.noteId] = localNote;
            peer.baseline[d.noteId] = localNote.versionVector;
            baseline[d.noteId] = localNote.versionVector;
          }

        case SyncAction.pushDelete:
          if (localNote != null) {
            peer.notes[d.noteId] = localNote;
            peer.baseline[d.noteId] = localNote.versionVector;
            baseline[d.noteId] = localNote.versionVector;
          }

        case SyncAction.conflict:
          if (localNote == null || remoteNote == null) break;
          // 生成冲突副本：较新者占原 noteId，较旧者新 noteId + 标题后缀。
          final res = SyncPlanner.resolveConflict(localNote, remoteNote);
          final loserId = '${res.loser.noteId}-conflict';
          final loser = res.loser.copyWith(
            noteId: loserId,
            title: '${res.loser.title}$conflictTitleSuffix',
          );
          // 两端都写入：胜者占原 id，败者另存
          notes[d.noteId] = res.winner;
          notes[loserId] = loser;
          peer.notes[d.noteId] = res.winner;
          peer.notes[loserId] = loser;
          // 合并版本向量，使两端一致
          final merged = res.winner.versionVector.merge(res.loser.versionVector);
          notes[d.noteId] = notes[d.noteId]!.copyWith(versionVector: merged, contentHash: 'merged-${merged.encode()}');
          peer.notes[d.noteId] = notes[d.noteId]!;
          baseline[d.noteId] = merged;
          peer.baseline[d.noteId] = merged;
          conflictIds?.add(d.noteId);
      }
    }
    return decisions;
  }
}

NoteMeta note(String id, {required String content, required Map<String, int> vv, int ts = 1000}) =>
    NoteMeta(
      noteId: id,
      title: 'T',
      content: content,
      versionVector: VersionVector(vv),
      contentHash: 'h-$content-$vv',
      createdAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
    );

void main() {
  group('两设备收敛（版本向量版）', () {
    test('一端新增 → 传播到另一端', () {
      final a = FakeDevice('dev-a', {'x': note('x', content: 'c', vv: {'dev-a': 1})});
      final b = FakeDevice('dev-b', {});

      a.syncWith(b);

      expect(b.notes.keys, contains('x'));
      expect(b.notes['x']!.versionVector, a.notes['x']!.versionVector);
    });

    test('双向同步后两端完全一致（多轮至稳定）', () {
      final a = FakeDevice('dev-a', {
        'shared': note('shared', content: 'a', vv: {'dev-a': 1}),
        'onlyA': note('onlyA', content: 'a2', vv: {'dev-a': 1}),
      });
      final b = FakeDevice('dev-b', {
        'shared': note('shared', content: 'b', vv: {'dev-b': 1}),
        'onlyB': note('onlyB', content: 'b2', vv: {'dev-b': 1}),
      });

      var guard = 0;
      while (guard++ < 12) {
        a.syncWith(b);
        b.syncWith(a);
        if (guard > 2) break; // 并发场景会在首次产生副本，之后即稳定
      }

      expect(a.notes.keys.toSet(), b.notes.keys.toSet());
      for (final id in a.notes.keys) {
        expect(a.notes[id]!.content, b.notes[id]!.content, reason: '笔记 $id 内容应收敛');
      }
    });

    test('A 同时编辑：晚者胜判定不影响"两份都保留"', () {
      // 真正的并发：双方各自在本地 +1，互不支配
      final a = FakeDevice('dev-a', {});
      final b = FakeDevice('dev-b', {});
      a.edit('x', 'A 的版本', ts: 1000);
      b.edit('x', 'B 的版本', ts: 2000);

      final conflicts = <String>[];
      a.syncWith(b, conflictIds: conflicts);

      expect(conflicts, contains('x'));
      // 两份内容都保留
      final contents = a.notes.values.map((n) => n.content).toSet();
      expect(contents.contains('A 的版本'), isTrue);
      expect(contents.contains('B 的版本'), isTrue);
    });

    test('冲突副本标题带后缀', () {
      final a = FakeDevice('dev-a', {});
      final b = FakeDevice('dev-b', {});
      a.edit('x', 'A', ts: 1000);
      b.edit('x', 'B', ts: 2000);

      a.syncWith(b);

      final hasSuffix = a.notes.values.any((n) => n.title.contains(conflictTitleSuffix));
      expect(hasSuffix, isTrue, reason: '必须留下标明为冲突副本的一份');
    });

    test('离线编辑 100 次后重连：只有单个待发动作（不产生 100 个 patch）', () {
      final a = FakeDevice('dev-a', {});
      final b = FakeDevice('dev-b', {});

      // 先同步一次建立基线
      a.edit('x', 'v0', ts: 1);
      a.syncWith(b);
      b.syncWith(a);

      // A 离线编辑 100 次
      for (var i = 1; i <= 100; i++) {
        a.edit('x', 'v$i', ts: 100 + i);
      }

      // B 未动 → A 侧的决策应是单个 patch
      final decisions = SyncPlanner.plan(
        local: a.notes,
        remote: b.notes,
        baselines: a.baseline,
      );
      expect(decisions.length, 1);
      expect(decisions.single.action, SyncAction.patch);
      expect(a.notes['x']!.versionVector['dev-a'], 101);
    });

    test('删除传播到对端', () {
      final a = FakeDevice('dev-a', {});
      final b = FakeDevice('dev-b', {});

      a.edit('x', 'c', ts: 1);
      a.syncWith(b);
      b.syncWith(a);

      a.edit('x', '', ts: 5, deleted: true);
      a.syncWith(b);

      expect(b.notes['x']!.isDeleted, isTrue);
    });

    test('空设备同步无动作', () {
      final a = FakeDevice('dev-a', {});
      final b = FakeDevice('dev-b', {});
      expect(a.syncWith(b), isEmpty);
    });

    test('一端为空 → 全量复制', () {
      final a = FakeDevice('dev-a', {});
      final b = FakeDevice('dev-b', {});
      for (var i = 0; i < 20; i++) {
        a.edit('n$i', 'c$i', ts: i + 1);
      }

      a.syncWith(b);
      expect(b.notes.length, 20);
    });
  });

  group('变更 10 验收项：并发必须保留两份', () {
    test('A、B 同时编辑同一篇 → 生成冲突副本，两份内容都在', () {
      final a = FakeDevice('dev-a', {});
      final b = FakeDevice('dev-b', {});
      a.edit('note', 'A 写的内容', ts: 1000);
      b.edit('note', 'B 写的内容', ts: 1001);

      a.syncWith(b);

      final contents = a.notes.values.map((n) => n.content).toSet();
      expect(contents, containsAll(<String>['A 写的内容', 'B 写的内容']));
      expect(a.notes.length, 2, reason: '原笔记 + 冲突副本');

      // B 侧也一样
      final bContents = b.notes.values.map((n) => n.content).toSet();
      expect(bContents, containsAll(<String>['A 写的内容', 'B 写的内容']));
    });

    test('并发不会静默丢弃任何一方（不得直接覆盖）', () {
      final a = FakeDevice('dev-a', {});
      final b = FakeDevice('dev-b', {});
      a.edit('note', '重要内容 A');
      b.edit('note', '重要内容 B');

      a.syncWith(b);

      final all = <String>[
        ...a.notes.values.map((n) => n.content),
        ...b.notes.values.map((n) => n.content),
      ];
      expect(all.where((c) => c == '重要内容 A').length, greaterThanOrEqualTo(2));
      expect(all.where((c) => c == '重要内容 B').length, greaterThanOrEqualTo(2));
    });
  });
}
