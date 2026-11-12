import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/db/database.dart';
import 'package:path/path.dart' as p;

/// 数据库 schema 的冒烟测试。
///
/// **本文件的存在是有来历的**：曾经 `@TableIndex(name: 'idx_notes_updated',
/// columns: {#updatedAt})` 被错放在 `SearchIndex` 表上，而 `updatedAt` 属于
/// `Notes` 表，drift 因此生成了
/// `CREATE INDEX idx_notes_updated ON search_index ()`（空列列表），
/// SQLite 直接语法报错，导致 `beforeOpen` 阶段建表失败 ——
/// **任何 AppDatabase 都打不开**，而这个问题在纯静态分析（analyze）下
/// 完全看不出来。所以这里用一个最小冒烟测试把它钉住。
void main() {
  late Directory dir;
  late AppDatabase db;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('schema_smoke');
    db = AppDatabase.atFile(File(p.join(dir.path, 'notes.db')));
  });

  tearDown(() async {
    await db.close();
    dir.deleteSync(recursive: true);
  });

  group('schema 建表（防回归）', () {
    test('打开数据库不抛异常，且三张表都建出来', () async {
      // 触发 beforeOpen（建 schema）
      await db.customSelect('SELECT 1').get();

      final tables = await db
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      final names = tables.map((r) => r.data['name'].toString()).toSet();

      expect(names, contains('notes'));
      expect(names, contains('sync_baselines'));
      expect(names, contains('search_index'));
    });

    test('索引 idx_notes_updated 建在 notes 表上且列非空', () async {
      await db.customSelect('SELECT 1').get();

      final idx = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE type='index' AND name='idx_notes_updated'",
          )
          .getSingleOrNull();

      expect(idx, isNotNull, reason: '索引 idx_notes_updated 应该存在');
      final sql = idx!.data['sql'].toString();

      // 关键断言：必须建在 notes 表上
      expect(sql, contains('ON notes'));
      expect(sql, isNot(contains('search_index')));
      // 关键断言：列列表不能为空（这正是当年那个 bug 的形态）
      expect(
        RegExp(r'\(\s*\)').hasMatch(sql),
        isFalse,
        reason: '索引列列表为空会导致 SQLite 语法错误：$sql',
      );
      expect(sql, contains('updated_at'));
    });

    test('所有 drift 索引的列列表都非空（通用防回归）', () async {
      await db.customSelect('SELECT 1').get();

      final indexes = await db
          .customSelect(
            "SELECT name, sql FROM sqlite_master WHERE type='index' AND sql IS NOT NULL",
          )
          .get();

      expect(indexes, isNotEmpty);
      for (final row in indexes) {
        final sql = row.data['sql'].toString();
        expect(
          RegExp(r'\(\s*\)').hasMatch(sql),
          isFalse,
          reason: '索引 ${row.data['name']} 的列列表为空：$sql',
        );
      }
    });

    test('完整性检查通过（变更 10 验收项）', () async {
      expect(await db.integrityCheck(), 'ok');
      expect(await db.isHealthy(), isTrue);
    });

    test('可正常写入并读回（验证 schema 真的可用）', () async {
      await db.upsertNote(
        noteId: 'n1',
        title: '标题',
        content: '# 标题\n正文',
        excerpt: '标题 正文',
        versionVector: '{"dev-a":1}',
        contentHash: 'hash1',
        imageHashesJson: '[]',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      final note = await db.noteById('n1');
      expect(note, isNotNull);
      expect(note!.title, '标题');
      expect(note.content, '# 标题\n正文');
    });
  });

  group('事务性（变更 10 验收项：写入中断无半写状态）', () {
    test('事务内抛异常 → 整体回滚，查不到这条记录', () async {
      await expectLater(
        db.transaction(() async {
          await db.upsertNote(
            noteId: 'rollback-me',
            title: 'T',
            content: 'C',
            excerpt: 'E',
            versionVector: '{}',
            contentHash: 'H',
            imageHashesJson: '[]',
            createdAt: DateTime.now().toUtc(),
            updatedAt: DateTime.now().toUtc(),
          );
          // 模拟写入过程中出错
          throw StateError('模拟写入中断');
        }),
        throwsA(isA<StateError>()),
      );

      // 关键断言：回滚后不应留下这条记录
      expect(await db.noteById('rollback-me'), isNull);
    });

    test('事务成功提交后记录可见', () async {
      await db.transaction(() async {
        await db.upsertNote(
          noteId: 'commit-me',
          title: 'T',
          content: 'C',
          excerpt: 'E',
          versionVector: '{}',
          contentHash: 'H',
          imageHashesJson: '[]',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        );
      });
      expect(await db.noteById('commit-me'), isNotNull);
    });

    test('多次写入后 integrity_check 仍为 ok', () async {
      for (var i = 0; i < 20; i++) {
        await db.upsertNote(
          noteId: 'n$i',
          title: 'T$i',
          content: 'C$i',
          excerpt: 'E',
          versionVector: '{"dev-a":$i}',
          contentHash: 'H$i',
          imageHashesJson: '[]',
          createdAt: DateTime.now().toUtc(),
          updatedAt: DateTime.now().toUtc(),
        );
      }
      expect(await db.integrityCheck(), 'ok');
      expect((await db.allNotes()).length, 20);
    });
  });

  group('VACUUM INTO 备份（变更 10 验收项：备份文件可被 SQLite 打开）', () {
    test('备份文件存在且能被 sqlite3 正常打开并查到数据', () async {
      await db.upsertNote(
        noteId: 'backup-me',
        title: '备份测试',
        content: '内容',
        excerpt: '内容',
        versionVector: '{}',
        contentHash: 'H',
        imageHashesJson: '[]',
        createdAt: DateTime.now().toUtc(),
        updatedAt: DateTime.now().toUtc(),
      );

      final target = File(p.join(dir.path, 'backups', 'notes_test.db'));
      await db.backupTo(target);

      expect(target.existsSync(), isTrue);
      expect(target.lengthSync(), greaterThan(0));

      // 用独立连接打开备份，确认是合法的 SQLite 库且数据在
      final restored = AppDatabase.atFile(target);
      try {
        final note = await restored.noteById('backup-me');
        expect(note, isNotNull, reason: '备份里应能查到原记录');
        expect(note!.title, '备份测试');
        expect(await restored.integrityCheck(), 'ok');
      } finally {
        await restored.close();
      }
    });

    test('对已存在的备份路径会先删除再写（可重复备份）', () async {
      final target = File(p.join(dir.path, 'b.db'));
      await db.backupTo(target);
      final first = target.lengthSync();
      await db.backupTo(target);
      expect(target.existsSync(), isTrue);
      expect(target.lengthSync(), greaterThan(0));
      expect(first, greaterThan(0));
    });
  });
}
