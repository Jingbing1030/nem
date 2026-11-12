import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:super_clipboard/super_clipboard.dart';

import 'image_vault.dart';
import '../providers.dart';

/// 图片导入的服务层：相册 / 文件 / 剪贴板 三条入口。
///
/// 三条入口最终都汇到 [ImageVault.import]，因此压缩、哈希、去重行为一致。
class ImagePickerService {
  ImagePickerService(this._vault);

  final ImageVault _vault;
  final ImagePicker _picker = ImagePicker();

  /// 相册选取（失败则回退到文件选择器，便于在桌面/无相册环境使用）。
  Future<ImageImportResult?> pickFromGalleryOrFiles() async {
    try {
      final picked = await _picker.pickImage(source: ImageSource.gallery);
      if (picked != null) {
        final bytes = await picked.readAsBytes();
        return _vault.import(bytes, p.extension(picked.path));
      }
      return null;
    } on PlatformException {
      return pickFromFiles();
    } on MissingPluginException {
      return pickFromFiles();
    }
  }

  /// 文件选择器导入（支持多选，此处取第一个）。
  ///
  /// file_picker 11 去掉了 `FilePicker.platform` 单例，`pickFiles` 变成静态方法。
  Future<ImageImportResult?> pickFromFiles() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null) return null;
    final file = File(path);
    return _vault.import(await file.readAsBytes(), p.extension(path));
  }

  /// 剪贴板导入图片。
  ///
  /// 只有剪贴板含图片格式时才返回结果，否则返回 null（由 UI 提示）。
  Future<ImageImportResult?> pickFromClipboard() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return null;

    final reader = await clipboard.read();

    // 1) 位图：PNG / JPEG
    for (final (format, ext) in <(FileFormat, String)>[
      (Formats.png, 'png'),
      (Formats.jpeg, 'jpg'),
    ]) {
      if (!reader.canProvide(format)) continue;
      final bytes = await _readAll(reader, format);
      if (bytes != null && bytes.isNotEmpty) return _vault.import(bytes, ext);
    }

    // 2) 文件 URI（从文件管理器复制图片的情况）
    if (reader.canProvide(Formats.fileUri)) {
      final uri = await reader.readValue(Formats.fileUri);
      if (uri != null && uri.scheme == 'file') {
        final file = File(uri.toFilePath());
        if (file.existsSync()) {
          return _vault.import(await file.readAsBytes(), p.extension(file.path));
        }
      }
    }
    return null;
  }

  /// 读完某个格式的全部字节。
  ///
  /// super_clipboard 的 getFile 是「回调 + 流」式 API：
  /// 流必须在 onFile 回调内取用（见 DataReaderFile.getStream 的约定）。
  Future<Uint8List?> _readAll(ClipboardReader reader, FileFormat format) async {
    Uint8List? collected;
    final progress = reader.getFile(format, (file) async {
      collected = await file.readAll();
    });
    if (progress == null) return null;
    // getFile 返回时回调已完成；再等一拍确保流被消费。
    await Future<void>.delayed(Duration.zero);
    return collected;
  }
}

final imagePickerServiceProvider = Provider<ImagePickerService>(
  (ref) => ImagePickerService(ref.watch(imageVaultProvider)),
);
