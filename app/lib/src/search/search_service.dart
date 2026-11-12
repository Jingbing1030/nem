import 'package:drift/drift.dart';

import '../db/database.dart';

/// 搜索抽象（变更 7：两个实现可切换）。
abstract class SearchService {
  /// 搜索笔记，返回按「标题命中优先 + updatedAt 倒序」排序的结果。
  Future<List<Note>> search(String query, {int limit = 100});

  /// 重建索引。
  Future<void> rebuild();
}

/// 阶段 1 实现：SQL LIKE（配合 notes.content/title）。
///
/// 简单可靠、无额外依赖。数据量超过阈值后切换到 FTS5 实现。
class LikeSearchService implements SearchService {
  LikeSearchService(this.db);

  final AppDatabase db;

  /// 切换阈值：总字数 > 1000 万（变更 7）。
  static const int ftsSwitchCharThreshold = 10000000;

  @override
  Future<List<Note>> search(String query, {int limit = 100}) async {
    final q = query.trim();
    if (q.isEmpty) return <Note>[];

    final pattern = '%${_escapeLike(q)}%';
    // 标题命中优先，其次按更新时间倒序。
    final rows = await db.customSelect(
      '''
      SELECT * FROM notes
      WHERE is_deleted = 0
        AND (title LIKE ?1 ESCAPE '\\' OR content LIKE ?1 ESCAPE '\\')
      ORDER BY
        CASE WHEN title LIKE ?1 ESCAPE '\\' THEN 0 ELSE 1 END,
        updated_at DESC
      LIMIT ?2
      ''',
      variables: <Variable<Object>>[
        Variable<String>(pattern),
        Variable<int>(limit),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{db.notes},
    ).get();

    return rows.map((row) => db.notes.map(row.data)).toList();
  }

  @override
  /// 重建 search_index 表的内容。
  ///
  /// LIKE 实现虽然直接查 notes 表，但 search_index 表仍存在
  /// （阶段 2 切 FTS5 时要用），因此这里**真正重建它**，
  /// 避免设置页的「重建索引」变成一个点了没反应的死按钮。
  Future<void> rebuild() async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM search_index');
      await db.customStatement(
        'INSERT INTO search_index (note_id, title, content) '
        'SELECT note_id, title, content FROM notes WHERE is_deleted = 0',
      );
    });
  }

  /// 转义 LIKE 的通配符，避免用户输入的 % 变成「匹配一切」。
  /// 转义 LIKE 通配符（供 FTS 实现复用）。
  static String escapeLike(String s) => _escapeLike(s);

  static String _escapeLike(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');
}

/// 阶段 2 实现：FTS5（unicode61 分词）。
///
/// 数据量大时启用。注意 FTS5 的 unicode61 对中文按「连续 CJK 视为一个词」处理，
/// 若中文检索效果不佳，需改用 bigram 分词器（见 README 已知限制）。
class FtsSearchService implements SearchService {
  FtsSearchService(this.db);

  final AppDatabase db;

  @override
  Future<List<Note>> search(String query, {int limit = 100}) async {
    final q = query.trim();
    if (q.isEmpty) return <Note>[];

    // FTS5 的 MATCH 语法需要把查询当作短语，避免用户输入被当作语法。
    final match = '"${q.replaceAll('"', '""')}"';
    final rows = await db.customSelect(
      '''
      SELECT n.* FROM notes n
      JOIN search_index f ON f.note_id = n.note_id
      WHERE n.is_deleted = 0 AND f.content MATCH ?1
      ORDER BY
        CASE WHEN n.title LIKE ?2 ESCAPE '\\' THEN 0 ELSE 1 END,
        n.updated_at DESC
      LIMIT ?3
      ''',
      variables: <Variable<Object>>[
        Variable<String>(match),
        Variable<String>('%${LikeSearchService.escapeLike(q)}%'),
        Variable<int>(limit),
      ],
      readsFrom: <ResultSetImplementation<dynamic, dynamic>>{db.notes},
    ).get();

    return rows.map((row) => db.notes.map(row.data)).toList();
  }

  @override
  Future<void> rebuild() async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM search_index');
      await db.customStatement(
        'INSERT INTO search_index (note_id, title, content) '
        'SELECT note_id, title, content FROM notes WHERE is_deleted = 0',
      );
    });
  }

  /// 依据数据规模决定是否该切到 FTS5。
  static Future<bool> shouldUseFts(AppDatabase db) async {
    final row = await db
        .customSelect('SELECT COALESCE(SUM(LENGTH(content) + LENGTH(title)), 0) AS n FROM notes')
        .getSingle();
    final total = (row.data['n'] as int?) ?? 0;
    return total > LikeSearchService.ftsSwitchCharThreshold;
  }
}
