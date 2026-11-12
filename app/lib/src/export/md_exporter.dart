import 'dart:io';

import 'package:notepad_core/notepad_core.dart';
import 'package:path/path.dart' as p;

import '../db/database.dart';
import '../db/paths.dart';

/// 导出结果。
class ExportResult {
  const ExportResult({
    required this.files,
    required this.imagesCopied,
    required this.targetDir,
  });

  /// 写出的 md 文件数。
  final int files;

  /// 复制的图片数。
  final int imagesCopied;

  /// 目标目录。
  final String targetDir;

  @override
  String toString() => 'ExportResult($files 篇, $imagesCopied 张图片 → $targetDir)';
}

/// Markdown 导出（变更 8）。
///
/// **必须包含图片复制**，保证导出产物可独立使用（变更 9）。
class MdExporter {
  MdExporter(this.db, this.paths);

  final AppDatabase db;
  final VaultPaths2 paths;

  /// 导出全部笔记到 [targetDir]（默认 exports/）。
  ///
  /// 文件名格式：`<title>_<noteId>.md`（文档规定）。
  Future<ExportResult> exportAll({Directory? targetDir}) async {
    final dir = targetDir ?? paths.exportsDir;
    await dir.create(recursive: true);

    final notes = await db.allNotes(includeDeleted: false);
    var count = 0;
    final neededImages = <String>{};

    for (final n in notes) {
      final content = n.content;
      neededImages.addAll(MarkdownDoc.extractImageHashes(content));
      final file = File(p.join(dir.path, '${_safeName(n.title)}_${n.noteId}.md'));
      await file.writeAsString(content, flush: true);
      count++;
    }

    final copied = await _copyImages(neededImages, dir);
    return ExportResult(files: count, imagesCopied: copied, targetDir: dir.path);
  }

  /// 导出单篇（编辑页菜单「导出为 md」）。
  Future<ExportResult> exportOne(String noteId, {Directory? targetDir}) async {
    final dir = targetDir ?? paths.exportsDir;
    await dir.create(recursive: true);

    final n = await db.noteById(noteId);
    if (n == null) {
      return ExportResult(files: 0, imagesCopied: 0, targetDir: dir.path);
    }

    final file = File(p.join(dir.path, '${_safeName(n.title)}_${n.noteId}.md'));
    await file.writeAsString(n.content, flush: true);

    final copied = await _copyImages(
      MarkdownDoc.extractImageHashes(n.content).toSet(),
      dir,
    );
    return ExportResult(files: 1, imagesCopied: copied, targetDir: dir.path);
  }

  /// 复制图片到 `<targetDir>/assets/images/`（保持 md 里的相对路径可用）。
  Future<int> _copyImages(Set<String> hashes, Directory targetDir) async {
    if (hashes.isEmpty) return 0;
    final dest = Directory(p.join(targetDir.path, 'assets', 'images'));
    await dest.create(recursive: true);

    var copied = 0;
    for (final hash in hashes) {
      final src = _findImage(hash);
      if (src == null) continue;
      final out = File(p.join(dest.path, p.basename(src.path)));
      // 已存在且大小一致则跳过（导出幂等）
      if (out.existsSync() && out.lengthSync() == src.lengthSync()) continue;
      await src.copy(out.path);
      copied++;
    }
    return copied;
  }

  File? _findImage(String hash) {
    if (!paths.imagesDir.existsSync()) return null;
    for (final e in paths.imagesDir.listSync()) {
      if (e is File && p.basename(e.path).startsWith('$hash.')) return e;
    }
    return null;
  }

  /// 文件名安全化：去掉路径分隔符与非法字符，空标题用「未命名」。
  static String _safeName(String title) {
    var t = title.trim();
    if (t.isEmpty) t = '未命名';
    t = t.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
    t = t.replaceAll(RegExp(r'\s+'), ' ');
    // 控制长度，避免超出文件系统上限
    if (t.length > 80) t = t.substring(0, 80);
    return t;
  }
}
