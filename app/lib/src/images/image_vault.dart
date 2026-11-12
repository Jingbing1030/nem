import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:notepad_core/notepad_core.dart';
import 'package:path/path.dart' as p;

import '../db/paths.dart';

/// 图片导入结果。
class ImageImportResult {
  const ImageImportResult({
    required this.hash,
    required this.ext,
    required this.relativeRef,
    required this.bytes,
    required this.deduplicated,
  });

  /// SHA-256（文件名主体）。
  final String hash;

  /// 扩展名（不含点）。
  final String ext;

  /// 写入 md 的相对引用：`assets/images/<hash>.<ext>`。
  final String relativeRef;

  /// 最终存储的字节（压缩后）。
  final Uint8List bytes;

  /// 是否命中了已有文件（内容寻址去重）。
  final bool deduplicated;
}

/// 图片仓库：压缩 → 哈希 → 内容寻址落盘。
class ImageVault {
  ImageVault(this.vault, {this.enabled = true});

  final VaultPaths2 vault;

  /// 是否压缩（需求：默认开启，可由配置关闭）。
  final bool enabled;

  /// 导入一张图片。
  ///
  /// 流程（需求 5.3）：
  /// 1. 压缩（长边 ≤1920，质量 85）
  /// 2. 算 SHA-256
  /// 3. 若已存在同哈希文件则**跳过写盘**（天然去重）
  /// 4. 返回可插入 md 的相对引用
  Future<ImageImportResult> import(List<int> rawBytes, String sourceExt) async {
    final compressed = enabled
        ? await _compress(rawBytes, sourceExt)
        : Uint8List.fromList(rawBytes);

    final hash = Hashing.sha256Hex(compressed);
    final ext = _normalizeExt(sourceExt);

    final existing = vault.imageExists(hash, ext);
    if (!existing) {
      final f = vault.imageFile(hash, ext);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(compressed, flush: true);
    }

    return ImageImportResult(
      hash: hash,
      ext: ext,
      relativeRef: VaultPaths.imageRef(hash, ext),
      bytes: compressed,
      deduplicated: existing,
    );
  }

  /// 压缩到长边 ≤1920、质量 85。
  ///
  /// 压缩失败（如格式不支持）时回退为原图，不阻断导入。
  Future<Uint8List> _compress(List<int> input, String ext) async {
    try {
      final out = await FlutterImageCompress.compressWithList(
        Uint8List.fromList(input),
        minWidth: ProtocolConst.imageMaxDimension,
        minHeight: ProtocolConst.imageMaxDimension,
        quality: ProtocolConst.imageQuality,
        // 保持原格式（除 png 转 png 外，统一走 jpeg 会丢透明通道，
        // 因此这里按扩展名决定）。
        format: _compressFormat(ext),
      );
      // 压缩后反而更大时保留原图。
      if (out.length >= input.length) return Uint8List.fromList(input);
      return out;
    } catch (_) {
      return Uint8List.fromList(input);
    }
  }

  CompressFormat _compressFormat(String ext) {
    switch (_normalizeExt(ext)) {
      case 'png':
        return CompressFormat.png;
      case 'webp':
        return CompressFormat.webp;
      default:
        return CompressFormat.jpeg;
    }
  }

  String _normalizeExt(String ext) {
    final e = (ext.startsWith('.') ? ext.substring(1) : ext).toLowerCase();
    if (e.isEmpty) return 'jpg';
    if (e == 'jpeg') return 'jpg';
    return e;
  }

  /// 从文件导入。
  Future<ImageImportResult> importFile(File file) =>
      import(file.readAsBytesSync(), p.extension(file.path));

  /// 写入对端传来的图片（已按哈希命名，直接校验后落盘）。
  Future<bool> storeReceived(
    String hash,
    String ext,
    List<int> bytes,
  ) async {
    // 内容寻址：哈希不匹配即拒绝入盘（防止污染与投毒）。
    if (!Hashing.matchesSha256(bytes, hash)) return false;
    final f = vault.imageFile(hash, ext);
    if (f.existsSync()) return true;
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    return true;
  }

  /// 图片 GC：删除没有被任何笔记引用的图片文件。
  ///
  /// **变更 1 的影响**：正文已入库，因此引用来源从「扫描 md 文件」
  /// 改为「查询数据库的 image_hashes 列」（该列在每次保存时维护）。
  /// 返回删除的文件数。
  Future<int> collectGarbage({required Set<String> referencedHashes}) async {
    var removed = 0;
    if (!vault.imagesDir.existsSync()) return 0;
    for (final f in vault.imagesDir.listSync().whereType<File>()) {
      final hash = p.basename(f.path).split('.').first;
      // 只有真正的 64 位十六进制哈希文件才参与 GC 判定，
      // 避免把用户手工放进来的其它文件误删。
      if (!isContentHash(hash)) continue;
      if (!referencedHashes.contains(hash)) {
        await f.delete();
        removed++;
      }
    }
    return removed;
  }
}
