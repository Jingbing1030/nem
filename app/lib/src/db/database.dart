import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;

part 'database.g.dart';

/// 笔记表（变更 3.1）。
///
/// **正文入库**：`content` 是唯一真相源，md 文件只是导出产物。
/// 索引说明：
/// - `idx_notes_updated` 加速列表页「按 updatedAt 倒序」与同步比较；
/// - `updatedAt` 属于本表，注解必须落在本表上（曾经误放在 SearchIndex 上，
///   导致生成的建表语句是 `ON search_index ()`（空列），SQLite 直接语法报错，
///   使**整库建表失败**）。
@TableIndex(name: 'idx_notes_updated', columns: {#updatedAt})
class Notes extends Table {
  /// note_id 主键（UUID）。
  TextColumn get noteId => text()();

  TextColumn get title => text()();

  /// Markdown 全文（新增）。
  TextColumn get content => text()();

  TextColumn get excerpt => text()();

  /// 版本向量 JSON（新增，替代单一 version int）。
  TextColumn get versionVector => text()();

  /// SHA-256(content)（新增）。
  TextColumn get contentHash => text()();

  /// JSON 数组（新增）。
  TextColumn get imageHashes => text()();

  BoolColumn get isDeleted => boolean().withDefault(const Constant(false))();

  IntColumn get createdAt => integer()();

  IntColumn get updatedAt => integer()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{noteId};
}

/// 同步基线表（变更 3.2，第一版没有）。
///
/// 记录「上次与某个对端同步时的版本向量与正文快照」，
/// 用于判断能否安全发增量 patch（baseText 从这里读，不再从文件读）。
class SyncBaselines extends Table {
  TextColumn get noteId => text()();
  TextColumn get peerDeviceId => text()();
  TextColumn get versionVector => text()();

  /// 上次与对端同步时的正文快照。
  TextColumn get baseText => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{noteId, peerDeviceId};
}

/// 全文搜索表（变更 3.3 / 变更 7）。
///
/// 阶段 1 用 FTS5 的 unicode61 分词（可先建表）。
/// 阶段 2 若需中文更好的分词，可换 bigram 分词器。
class SearchIndex extends Table {
  TextColumn get noteId => text()();
  TextColumn get title => text()();
  TextColumn get content => text()();

  @override
  Set<Column<Object>> get primaryKey => <Column<Object>>{noteId};
}

@DriftDatabase(tables: <Type>[Notes, SyncBaselines, SearchIndex])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// 直接指定文件路径打开（测试与生产都走这条）。
  AppDatabase.atFile(File file) : super(NativeDatabase.createInBackground(file));

  @override
  int get schemaVersion => 1;

  // ------------------------------------------------------------ 启动自检

  /// 启动时完整性检查（变更 9：必须跑 PRAGMA integrity_check）。
  Future<String> integrityCheck() async {
    final row = await customSelect('PRAGMA integrity_check').getSingle();
    return row.data.values.first?.toString() ?? 'unknown';
  }

  /// 是否通过了完整性检查。
  Future<bool> isHealthy() async => (await integrityCheck()).toLowerCase() == 'ok';

  /// 启用外键（drift 默认不开）。
  Future<void> enableForeignKeys() async {
    await customStatement('PRAGMA foreign_keys = ON');
  }

  // ------------------------------------------------------------ 事务写入

  /// 保存/更新一篇笔记（**所有写操作包事务**，变更 9）。
  Future<void> upsertNote({
    required String noteId,
    required String title,
    required String content,
    required String excerpt,
    required String versionVector,
    required String contentHash,
    required String imageHashesJson,
    required DateTime createdAt,
    required DateTime updatedAt,
    bool isDeleted = false,
  }) async {
    await transaction(() async {
      await into(notes).insertOnConflictUpdate(
        NotesCompanion.insert(
          noteId: noteId,
          title: title,
          content: content,
          excerpt: excerpt,
          versionVector: versionVector,
          contentHash: contentHash,
          imageHashes: imageHashesJson,
          isDeleted: Value(isDeleted),
          createdAt: createdAt.millisecondsSinceEpoch,
          updatedAt: updatedAt.millisecondsSinceEpoch,
        ),
      );
      await _reindex(noteId, title, content);
    });
  }

  /// 软删除（保留墓碑以便传播）。
  Future<void> softDelete(String noteId, {required DateTime updatedAt, required String versionVector}) async {
    await transaction(() async {
      await (update(notes)..where((t) => t.noteId.equals(noteId))).write(
        NotesCompanion(
          isDeleted: const Value(true),
          content: const Value(''),
          updatedAt: Value(updatedAt.millisecondsSinceEpoch),
          versionVector: Value(versionVector),
        ),
      );
      await (delete(searchIndex)..where((t) => t.noteId.equals(noteId))).go();
    });
  }

  Future<void> _reindex(String noteId, String title, String content) async {
    await (delete(searchIndex)..where((t) => t.noteId.equals(noteId))).go();
    await into(searchIndex).insert(
      SearchIndexCompanion.insert(noteId: noteId, title: title, content: content),
    );
  }

  // ------------------------------------------------------------ 读取

  Future<List<Note>> allNotes({bool includeDeleted = true}) async {
    final q = select(notes);
    if (!includeDeleted) {
      q.where((t) => t.isDeleted.equals(false));
    }
    q.orderBy(<OrderClauseGenerator<$NotesTable>>[
      (t) => OrderingTerm(expression: t.updatedAt, mode: OrderingMode.desc),
    ]);
    return q.get();
  }

  Future<Note?> noteById(String noteId) =>
      (select(notes)..where((t) => t.noteId.equals(noteId))).getSingleOrNull();

  // ------------------------------------------------------------ 同步基线

  Future<void> saveBaseline({
    required String noteId,
    required String peerDeviceId,
    required String versionVector,
    required String baseText,
  }) async {
    await into(syncBaselines).insertOnConflictUpdate(
      SyncBaselinesCompanion.insert(
        noteId: noteId,
        peerDeviceId: peerDeviceId,
        versionVector: versionVector,
        baseText: baseText,
      ),
    );
  }

  Future<SyncBaseline?> baselineFor(String noteId, String peerDeviceId) =>
      (select(syncBaselines)
            ..where((t) => t.noteId.equals(noteId) & t.peerDeviceId.equals(peerDeviceId)))
          .getSingleOrNull();

  Future<Map<String, String>> baselinesForPeer(String peerDeviceId) async {
    final rows = await (select(syncBaselines)
          ..where((t) => t.peerDeviceId.equals(peerDeviceId)))
        .get();
    return <String, String>{for (final r in rows) r.noteId: r.versionVector};
  }

  // ------------------------------------------------------------ 备份

  /// VACUUM INTO 备份（变更 8：每天首次编辑后）。
  ///
  /// 返回备份文件路径。目标文件必须不存在（SQLite 的 VACUUM INTO 要求）。
  Future<File> backupTo(File target) async {
    await target.parent.create(recursive: true);
    if (target.existsSync()) await target.delete();
    // 用参数化避免路径转义问题；VACUUM INTO 不支持参数绑定，故手工转义单引号。
    final escaped = target.path.replaceAll("'", "''");
    await customStatement("VACUUM INTO '$escaped'");
    return target;
  }
}
