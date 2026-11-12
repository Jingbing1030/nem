import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/db/database.dart';
import 'package:notepad_core/notepad_core.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sql;

/// `AppDatabase`（drift：正文 + 元数据 + 基线 + FTS 同一个库）单元测试。
void main() {
  late Directory tmp;
  late AppDatabase db;
  final t0 = DateTime.utc(2026, 11, 12, 10, 0, 0);

  File dbFile() => File(p.join(tmp.path, 'notes.db'));

  AppDatabase open() => AppDatabase.atFile(dbFile());

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('database_test');
    db = open();
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> seed({
    String noteId = 'n1',
    String title = '标题',
    String content = '正文',
    String vv = '{"dev-A":1}',
    bool isDeleted = false,
    int? updatedAtMs,
  }) =>
      db.upsertNote(
        noteId: noteId,
        title: title,
        content: content,
        excerpt: content,
        versionVector: vv,
        contentHash: Hashing.contentHash(content),
        imageHashesJson: '[]',
        createdAt: t0,
        updatedAt:
            updatedAtMs == null ? t0 : DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
        isDeleted: isDeleted,
      );

  group('完整性自检（变更 9）', () {
    test('空库 integrityCheck 返回 ok', () async {
      expect(await db.integrityCheck(), 'ok');
    });

    test('写入数据后仍然 ok', () async {
      await seed();
      expect(await db.integrityCheck(), 'ok');
    });

    test('isHealthy 是 integrityCheck 的布尔封装', () async {
      expect(await db.isHealthy(), isTrue);
    });

    test('表结构与预期一致：notes / sync_baselines / search_index', () async {
      final rows = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
          .get();
      final names = rows.map((r) => r.data['name'] as String).toSet();
      expect(names, containsAll(<String>['notes', 'sync_baselines', 'search_index']));
    });

    test('notes 表含 content 列（正文入库的关键验收点）', () async {
      final rows = await db.customSelect('PRAGMA table_info(notes)').get();
      final cols = rows.map((r) => r.data['name'] as String).toSet();
      expect(cols, containsAll(<String>[
        'note_id',
        'title',
        'content',
        'excerpt',
        'version_vector',
        'content_hash',
        'image_hashes',
        'is_deleted',
        'created_at',
        'updated_at',
      ]));
    });

    test('idx_notes_updated 索引真的建在 notes(updated_at) 上', () async {
      final rows = await db
          .customSelect("SELECT sql FROM sqlite_master WHERE type = 'index' AND name = 'idx_notes_updated'")
          .get();
      expect(rows.length, 1, reason: '索引应存在');
      final sqlText = rows.single.data['sql'] as String;
      expect(sqlText, contains('notes'));
      expect(sqlText, contains('updated_at'),
          reason: '索引列不能为空：$sqlText');
      // 让 SQLite 自己确认这个索引可用
      final plan = await db
          .customSelect('EXPLAIN QUERY PLAN '
              'SELECT note_id FROM notes ORDER BY updated_at DESC')
          .get();
      expect(plan.map((r) => r.data.values.last.toString()).join(),
          contains('idx_notes_updated'));
    });

    test('enableForeignKeys 不抛异常', () async {
      await db.enableForeignKeys();
      final rows = await db.customSelect('PRAGMA foreign_keys').get();
      expect(rows.single.data.values.first, 1);
    });
  });

  group('backupTo：VACUUM INTO 备份', () {
    test('生成的备份文件能被 sqlite3 正常打开并查到数据', () async {
      await seed(noteId: 'n1', title: '备份标题', content: '备份正文');
      final target = File(p.join(tmp.path, 'backups', 'notes_2026-11-12.db'));

      final out = await db.backupTo(target);

      expect(out.path, target.path);
      expect(target.existsSync(), isTrue);
      expect(target.lengthSync(), greaterThan(0));

      // 关键验收：用独立的 sqlite3 连接打开备份文件
      final raw = sql.sqlite3.open(target.path);
      try {
        expect(raw.select('PRAGMA integrity_check').single.values.first, 'ok');
        final rows = raw.select('SELECT note_id, title, content FROM notes');
        expect(rows.length, 1);
        expect(rows.single['title'], '备份标题');
        expect(rows.single['content'], '备份正文');
        expect(
          raw
              .select("SELECT name FROM sqlite_master WHERE type='table'")
              .map((r) => r['name'])
              .toSet(),
          containsAll(<String>['notes', 'sync_baselines', 'search_index']),
        );
      } finally {
        raw.dispose();
      }
    });

    test('备份是快照：后续写入不会改变已生成的备份', () async {
      await seed(noteId: 'n1', content: '第一版');
      final target = File(p.join(tmp.path, 'snap.db'));
      await db.backupTo(target);

      await seed(noteId: 'n2', content: '第二版');

      final raw = sql.sqlite3.open(target.path);
      try {
        expect(raw.select('SELECT COUNT(*) AS n FROM notes').single['n'], 1);
      } finally {
        raw.dispose();
      }
      expect((await db.allNotes()).length, 2);
    });

    test('目标父目录不存在时自动创建', () async {
      final target = File(p.join(tmp.path, 'a', 'b', 'c', 'x.db'));
      await db.backupTo(target);
      expect(target.existsSync(), isTrue);
    });

    test('目标文件已存在时先删除再重建（VACUUM INTO 的要求）', () async {
      final target = File(p.join(tmp.path, 'exist.db'))
        ..writeAsStringSync('垃圾内容，不是数据库');

      await seed(noteId: 'n1');
      await db.backupTo(target);

      final raw = sql.sqlite3.open(target.path);
      try {
        expect(raw.select('PRAGMA integrity_check').single.values.first, 'ok');
        expect(raw.select('SELECT COUNT(*) AS n FROM notes').single['n'], 1);
      } finally {
        raw.dispose();
      }
    });

    test('路径里带单引号也能正常备份（转义正确）', () async {
      final dir = Directory(p.join(tmp.path, "it's tricky"))
        ..createSync(recursive: true);
      final target = File(p.join(dir.path, 'notes.db'));
      await seed();
      await db.backupTo(target);
      expect(target.existsSync(), isTrue);
      final raw = sql.sqlite3.open(target.path);
      try {
        expect(raw.select('PRAGMA integrity_check').single.values.first, 'ok');
      } finally {
        raw.dispose();
      }
    });
  });

  group('同步基线（变更 3.2）', () {
    test('saveBaseline → baselineFor 往返一致', () async {
      await db.saveBaseline(
        noteId: 'n1',
        peerDeviceId: 'dev-B',
        versionVector: '{"dev-A":3}',
        baseText: '基线正文',
      );

      final b = await db.baselineFor('n1', 'dev-B');
      expect(b, isNotNull);
      expect(b!.noteId, 'n1');
      expect(b.peerDeviceId, 'dev-B');
      expect(b.versionVector, '{"dev-A":3}');
      expect(b.baseText, '基线正文');
    });

    test('同一 (noteId, peer) 重复保存是覆盖而非新增', () async {
      await db.saveBaseline(
        noteId: 'n1',
        peerDeviceId: 'dev-B',
        versionVector: '{"dev-A":1}',
        baseText: '旧',
      );
      await db.saveBaseline(
        noteId: 'n1',
        peerDeviceId: 'dev-B',
        versionVector: '{"dev-A":2}',
        baseText: '新',
      );
      final rows = await db.select(db.syncBaselines).get();
      expect(rows.length, 1);
      expect((await db.baselineFor('n1', 'dev-B'))!.baseText, '新');
    });

    test('基线按 (noteId, peerDeviceId) 二维隔离', () async {
      await db.saveBaseline(
          noteId: 'n1', peerDeviceId: 'dev-B', versionVector: '{"A":1}', baseText: 'n1-B');
      await db.saveBaseline(
          noteId: 'n1', peerDeviceId: 'dev-C', versionVector: '{"A":2}', baseText: 'n1-C');
      await db.saveBaseline(
          noteId: 'n2', peerDeviceId: 'dev-B', versionVector: '{"A":3}', baseText: 'n2-B');

      expect((await db.baselineFor('n1', 'dev-B'))!.baseText, 'n1-B');
      expect((await db.baselineFor('n1', 'dev-C'))!.baseText, 'n1-C');
      expect((await db.baselineFor('n2', 'dev-B'))!.baseText, 'n2-B');
      expect(await db.baselineFor('n2', 'dev-C'), isNull);
    });

    test('baselinesForPeer 返回「noteId → versionVector」的映射', () async {
      await db.saveBaseline(
          noteId: 'n1', peerDeviceId: 'dev-B', versionVector: '{"A":1}', baseText: 'x');
      await db.saveBaseline(
          noteId: 'n2', peerDeviceId: 'dev-B', versionVector: '{"A":2}', baseText: 'y');
      await db.saveBaseline(
          noteId: 'n3', peerDeviceId: 'dev-C', versionVector: '{"A":9}', baseText: 'z');

      final m = await db.baselinesForPeer('dev-B');
      expect(m, <String, String>{'n1': '{"A":1}', 'n2': '{"A":2}'});
      expect(await db.baselinesForPeer('dev-C'), <String, String>{'n3': '{"A":9}'});
      expect(await db.baselinesForPeer('dev-Z'), isEmpty);
    });

    test('基线文本允许为空串（首次同步前）', () async {
      await db.saveBaseline(
          noteId: 'n1', peerDeviceId: 'dev-B', versionVector: '{}', baseText: '');
      expect((await db.baselineFor('n1', 'dev-B'))!.baseText, '');
    });
  });

  group('allNotes / noteById', () {
    test('allNotes(includeDeleted: false) 过滤墓碑', () async {
      await seed(noteId: 'live-1', isDeleted: false);
      await seed(noteId: 'tomb-1', isDeleted: true, content: '');
      await seed(noteId: 'live-2', isDeleted: false);

      final live = await db.allNotes(includeDeleted: false);
      expect(live.map((n) => n.noteId).toSet(), <String>{'live-1', 'live-2'});
      expect((await db.allNotes()).length, 3);
    });

    test('allNotes 按 updatedAt 倒序', () async {
      await seed(noteId: 'old', updatedAtMs: 1000);
      await seed(noteId: 'new', updatedAtMs: 3000);
      await seed(noteId: 'mid', updatedAtMs: 2000);
      expect(
        (await db.allNotes()).map((n) => n.noteId).toList(),
        <String>['new', 'mid', 'old'],
      );
    });

    test('墓碑参与排序（同步需要知道最近删了什么）', () async {
      await seed(noteId: 'a', updatedAtMs: 1000);
      await seed(noteId: 'b', isDeleted: true, updatedAtMs: 5000);
      expect((await db.allNotes()).first.noteId, 'b');
      expect((await db.allNotes(includeDeleted: false)).first.noteId, 'a');
    });

    test('noteById 命中与未命中', () async {
      await seed(noteId: 'n1');
      expect((await db.noteById('n1'))!.noteId, 'n1');
      expect(await db.noteById('nope'), isNull);
    });
  });

  group('重启后库可用（同一文件重开）', () {
    test('关库再开，数据与基线都还在', () async {
      await seed(noteId: 'n1', title: '重启前');
      await db.saveBaseline(
          noteId: 'n1', peerDeviceId: 'dev-B', versionVector: '{"A":1}', baseText: 'base');
      await db.close();

      db = open();
      expect((await db.noteById('n1'))!.title, '重启前');
      expect((await db.baselineFor('n1', 'dev-B'))!.baseText, 'base');
      expect(await db.integrityCheck(), 'ok');
    });

    test('重启后 schemaVersion 不重复建表（不会丢数据）', () async {
      await seed(noteId: 'n1');
      await db.close();
      db = open();
      await seed(noteId: 'n2');
      expect(await db.allNotes().then((l) => l.length), 2);
    });
  });
}
