import '../version/version_vector.dart';

/// 笔记元数据 + 正文（变更 3.1：正文入库）。
///
/// 与第一版的区别：
/// - 新增 [content]（Markdown 全文）
/// - 新增 [versionVector]（替代单一 version int）
/// - 新增 [contentHash]（SHA-256(content)）
class NoteMeta {
  const NoteMeta({
    required this.noteId,
    required this.title,
    required this.content,
    required this.versionVector,
    required this.contentHash,
    required this.createdAt,
    required this.updatedAt,
    this.excerpt = '',
    this.imageHashes = const <String>[],
    this.isDeleted = false,
  });

  final String noteId;
  final String title;

  /// Markdown 全文（DB 为真相源）。
  final String content;

  /// 版本向量（deviceId → 计数）。
  final VersionVector versionVector;

  /// SHA-256(content)，用于快速判断内容是否真的相同。
  final String contentHash;

  final DateTime createdAt;
  final DateTime updatedAt;
  final String excerpt;
  final List<String> imageHashes;
  final bool isDeleted;

  /// 连接后交换的摘要（变更 6.2：note_summary）。
  ///
  /// **不含正文**，只有判断是否需要同步所需的字段。
  Map<String, dynamic> toSummary() => <String, dynamic>{
        'noteId': noteId,
        'versionVector': versionVector.counters,
        'contentHash': contentHash,
        'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
        'isDeleted': isDeleted,
        'title': title,
      };

  /// 全量推送载荷（note_push，变更 6.2 增加了 versionVector / contentHash）。
  Map<String, dynamic> toPushPayload() => <String, dynamic>{
        'noteId': noteId,
        'title': title,
        'content': content,
        'versionVector': versionVector.counters,
        'contentHash': contentHash,
        'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
        'imageHashes': imageHashes,
      };

  /// 从 note_summary 条目还原（无正文）。
  static NoteMeta fromSummary(Map<String, dynamic> json) {
    final vvRaw = json['versionVector'];
    final vv = vvRaw is Map
        ? VersionVector(<String, int>{
            for (final e in vvRaw.entries)
              e.key.toString():
                  e.value is int ? e.value as int : int.tryParse('${e.value}') ?? 0,
          })
        : VersionVector.empty();

    final updatedAt = DateTime.fromMillisecondsSinceEpoch(
      (json['updatedAt'] as int?) ?? 0,
      isUtc: true,
    );

    return NoteMeta(
      noteId: json['noteId'] as String,
      title: (json['title'] as String?) ?? '',
      content: '',
      versionVector: vv,
      contentHash: (json['contentHash'] as String?) ?? '',
      // 说明：note_summary **不携带 createdAt**（摘要只用于判断是否需要同步）。
      // 这里沿用 updatedAt 作为占位，仅供排序/比较使用；**它不是真实创建时间**。
      // 真正的 createdAt 由本地库保留（writeFromPeer 会保留本地已有的值），
      // 因此同步不会污染创建时间。调用方若要展示创建时间，必须读本地库，
      // 不能用从摘要还原出来的这个值。
      createdAt: updatedAt,
      updatedAt: updatedAt,
      isDeleted: (json['isDeleted'] as bool?) ?? false,
    );
  }

  /// 从 note_push 载荷还原（含正文）。
  static NoteMeta? fromPush(Map<String, dynamic> json) {
    final noteId = json['noteId'] as String?;
    final content = json['content'] as String?;
    if (noteId == null || content == null) return null;

    final vvRaw = json['versionVector'];
    final vv = vvRaw is Map
        ? VersionVector(<String, int>{
            for (final e in vvRaw.entries)
              e.key.toString():
                  e.value is int ? e.value as int : int.tryParse('${e.value}') ?? 0,
          })
        : VersionVector.empty();

    final ts = (json['updatedAt'] as int?) ?? 0;
    return NoteMeta(
      noteId: noteId,
      title: (json['title'] as String?) ?? '',
      content: content,
      versionVector: vv,
      contentHash: (json['contentHash'] as String?) ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true),
      imageHashes: ((json['imageHashes'] as List?) ?? <dynamic>[])
          .map((e) => e.toString())
          .toList(),
    );
  }

  NoteMeta copyWith({
    String? noteId,
    String? title,
    String? content,
    VersionVector? versionVector,
    String? contentHash,
    DateTime? updatedAt,
    List<String>? imageHashes,
    bool? isDeleted,
  }) =>
      NoteMeta(
        noteId: noteId ?? this.noteId,
        title: title ?? this.title,
        content: content ?? this.content,
        versionVector: versionVector ?? this.versionVector,
        contentHash: contentHash ?? this.contentHash,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        excerpt: excerpt,
        imageHashes: imageHashes ?? this.imageHashes,
        isDeleted: isDeleted ?? this.isDeleted,
      );

  @override
  String toString() => 'NoteMeta($noteId, "$title", vv=$versionVector, '
      'hash=${contentHash.isEmpty ? "-" : contentHash.substring(0, 8)}, deleted=$isDeleted)';
}

/// 冲突副本的标题后缀（变更 6.1：分叉时保留两份）。
const String conflictTitleSuffix = '（冲突副本）';
