import 'dart:convert';

import 'package:notepad_core/notepad_core.dart';

import 'database.dart';
import 'paths.dart';

/// 笔记仓库（变更 1：**正文以 DB 为唯一真相源**）。
///
/// 与第一版的关键差异：
/// - 正文读写在 SQLite 里，不再碰 md 文件
/// - 每次写入都自增版本向量并重算 contentHash
/// - 所有写操作包事务（由 [AppDatabase] 保证）
/// - 编辑时同步维护「与本对端的基线」，供增量 patch 使用
class NoteRepository2 {
  NoteRepository2({
    required this.db,
    required this.paths,
    required this.deviceId,
    this.clock = DateTime.now,
  });

  final AppDatabase db;
  final VaultPaths2 paths;

  /// 本机设备 id（版本向量的键）。
  final String deviceId;

  /// 可注入时钟，便于测试。
  final DateTime Function() clock;

  /// 新建笔记（标题/正文先给空，编辑页再填）。
  Future<String> create({String content = '', String title = ''}) async {
    final now = clock().toUtc();
    final noteId = newNoteId();
    final vv = VersionVector.empty().increment(deviceId);

    await db.upsertNote(
      noteId: noteId,
      title: title.isEmpty ? MarkdownDoc.extractTitle(content) : title,
      content: content,
      excerpt: MarkdownDoc.extractExcerpt(content),
      versionVector: vv.encode(),
      contentHash: Hashing.contentHash(content),
      imageHashesJson: jsonEncode(MarkdownDoc.extractImageHashes(content)),
      createdAt: now,
      updatedAt: now,
    );
    return noteId;
  }

  /// 保存正文（本地编辑）。
  ///
  /// 版本向量自增；返回更新后的版本向量，供调用方决定是否触发同步。
  Future<VersionVector> saveContent(String noteId, String content) async {
    final existing = await db.noteById(noteId);
    final now = clock().toUtc();
    final vv = VersionVector.decode(existing?.versionVector ?? '{}').increment(deviceId);

    await db.upsertNote(
      noteId: noteId,
      title: MarkdownDoc.extractTitle(content),
      content: content,
      excerpt: MarkdownDoc.extractExcerpt(content),
      versionVector: vv.encode(),
      contentHash: Hashing.contentHash(content),
      imageHashesJson: jsonEncode(MarkdownDoc.extractImageHashes(content)),
      createdAt: existing?.createdAt == null
          ? now
          : DateTime.fromMillisecondsSinceEpoch(existing!.createdAt, isUtc: true),
      updatedAt: now,
      isDeleted: existing?.isDeleted ?? false,
    );
    return vv;
  }

  /// 用对端内容覆盖（**同步接收时使用**）。
  ///
  /// 版本向量取「双方逐项最大值」，保证两端收敛。
  Future<void> writeFromPeer({
    required String noteId,
    required String content,
    required VersionVector remoteVersionVector,
    required String contentHash,
    required List<String> imageHashes,
    String? title,
  }) async {
    final existing = await db.noteById(noteId);
    final now = clock().toUtc();
    final local = VersionVector.decode(existing?.versionVector ?? '{}');
    final merged = local.merge(remoteVersionVector);

    await db.upsertNote(
      noteId: noteId,
      title: title?.isNotEmpty == true ? title! : MarkdownDoc.extractTitle(content),
      content: content,
      excerpt: MarkdownDoc.extractExcerpt(content),
      versionVector: merged.encode(),
      contentHash: contentHash.isEmpty ? Hashing.contentHash(content) : contentHash,
      imageHashesJson: jsonEncode(imageHashes),
      createdAt: existing?.createdAt == null
          ? now
          : DateTime.fromMillisecondsSinceEpoch(existing!.createdAt, isUtc: true),
      updatedAt: now,
      isDeleted: false,
    );
  }

  /// 本地软删除（版本向量自增以便传播）。
  Future<VersionVector> softDelete(String noteId) async {
    final existing = await db.noteById(noteId);
    final vv = VersionVector.decode(existing?.versionVector ?? '{}').increment(deviceId);
    await db.softDelete(
      noteId,
      updatedAt: clock().toUtc(),
      versionVector: vv.encode(),
    );
    return vv;
  }

  /// 应用对端删除（合并版本向量，保留墓碑）。
  Future<void> applyRemoteDelete(String noteId, VersionVector remote) async {
    final existing = await db.noteById(noteId);
    if (existing == null) return;
    final local = VersionVector.decode(existing.versionVector);
    await db.softDelete(
      noteId,
      updatedAt: clock().toUtc(),
      versionVector: local.merge(remote).encode(),
    );
  }

  /// 写入冲突副本（变更 6.1：分叉时两份都保留）。
  ///
  /// 较旧的一份使用新 noteId，标题加后缀。
  ///
  /// **id 必须带随机成分**：早期实现只用 `(noteId, 当前毫秒)` 拼 id，
  /// 配合 `upsertNote` 的 `insertOnConflictUpdate` 语义，
  /// **同一毫秒内两次调用会生成同一个 id，第二次静默覆盖第一次，
  /// 导致一份冲突副本被丢弃** —— 这恰好破坏了本函数
  /// 「分叉时两份都保留」的设计目的（已验证：库里只有 2 行而非 3 行）。
  ///
  /// 因此这里附加 4 字节安全随机数作为消歧后缀。选择「保留 `-c` 前缀 + 随机后缀」
  /// 而不是直接用 UUID，是为了让副本 id 仍能一眼看出「它是谁的副本」，
  /// 便于人工排查同步问题。
  Future<String> saveConflictCopy(NoteMeta loser) async {
    final now = clock().toUtc();
    final suffix = SecureRandomBytes.generate(4)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final newId =
        '${loser.noteId}-c${now.millisecondsSinceEpoch.toRadixString(36)}-$suffix';
    await db.upsertNote(
      noteId: newId,
      title: '${loser.title.isEmpty ? '未命名' : loser.title}$conflictTitleSuffix',
      content: loser.content,
      excerpt: loser.excerpt.isEmpty
          ? MarkdownDoc.extractExcerpt(loser.content)
          : loser.excerpt,
      versionVector: loser.versionVector.encode(),
      contentHash: loser.contentHash.isEmpty
          ? Hashing.contentHash(loser.content)
          : loser.contentHash,
      imageHashesJson: jsonEncode(loser.imageHashes),
      createdAt: now,
      updatedAt: now,
    );
    return newId;
  }

  /// 全部笔记（含墓碑），按 updatedAt 倒序。
  Future<List<Note>> all({bool includeDeleted = true}) =>
      db.allNotes(includeDeleted: includeDeleted);

  /// 列表页数据（排除墓碑）。
  Future<List<Note>> visibleNotes() => db.allNotes(includeDeleted: false);

  /// 转成同步模型。
  static NoteMeta toMeta(Note n) {
    List<String> hashes;
    try {
      hashes = (jsonDecode(n.imageHashes) as List).map((e) => e.toString()).toList();
    } catch (_) {
      hashes = <String>[];
    }
    return NoteMeta(
      noteId: n.noteId,
      title: n.title,
      content: n.content,
      versionVector: VersionVector.decode(n.versionVector),
      contentHash: n.contentHash,
      createdAt: DateTime.fromMillisecondsSinceEpoch(n.createdAt, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(n.updatedAt, isUtc: true),
      excerpt: n.excerpt,
      imageHashes: hashes,
      isDeleted: n.isDeleted,
    );
  }

  /// 生成本机 UUID v4。
  static String newNoteId() => genUuidV4();
}

/// UUID v4（安全随机）。
String genUuidV4() {
  final b = SecureRandomBytes.generate(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
