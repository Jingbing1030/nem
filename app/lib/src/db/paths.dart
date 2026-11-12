import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 笔记库目录布局（变更 4）。
///
/// ```
/// notepad/
/// ├── notes.db                    # 正文 + 元数据 + 基线 + FTS
/// ├── backups/                    # VACUUM INTO 备份 + md 快照
/// ├── exports/                    # 用户导出 md 的目录
/// └── assets/images/<sha256>.<ext>  # 图片仍为文件
/// ```
///
/// 与第一版相比：**删除 `notes/` 作为常驻存储**。
/// 内容哈希的严格形式：64 位小写十六进制（SHA-256）。
final RegExp _contentHashPattern = RegExp(r'^[0-9a-f]{64}$');

class VaultPaths2 {
  VaultPaths2._(this.root);

  final Directory root;

  /// 用指定根目录构造（测试用）。
  factory VaultPaths2.at(Directory root) => VaultPaths2._(root);

  /// 打开应用文档目录下的 notepad/。
  static Future<VaultPaths2> open() async {
    final docs = await getApplicationDocumentsDirectory();
    final v = VaultPaths2._(Directory(p.join(docs.path, 'notepad')));
    await v.ensureLayout();
    return v;
  }

  Future<void> ensureLayout() async {
    for (final d in <Directory>[imagesDir, backupsDir, exportsDir, themeDir]) {
      if (!d.existsSync()) await d.create(recursive: true);
    }
  }

  File get dbFile => File(p.join(root.path, 'notes.db'));

  Directory get imagesDir => Directory(p.join(root.path, 'assets', 'images'));

  Directory get backupsDir => Directory(p.join(root.path, 'backups'));

  Directory get exportsDir => Directory(p.join(root.path, 'exports'));

  /// 主题背景目录（**不属于 assets/images**，变更保持不变）。
  Directory get themeDir => Directory(p.join(root.path, 'theme'));

  /// 每日备份文件。
  File dailyBackup(DateTime day) {
    final d = day.toLocal();
    final name = 'notes_${d.year}-${_2(d.month)}-${_2(d.day)}.db';
    return File(p.join(backupsDir.path, name));
  }

  /// md 快照目录。
  Directory mdSnapshot(DateTime day) {
    final d = day.toLocal();
    return Directory(
      p.join(backupsDir.path, 'md_snapshot_${d.year}-${_2(d.month)}-${_2(d.day)}'),
    );
  }

  /// 图片文件（内容寻址，不变）。
  File imageFile(String hash, String ext) => File(
        p.join(imagesDir.path,
            '$hash.${ext.startsWith('.') ? ext.substring(1) : ext}'),
      );

  bool imageExists(String hash, String ext) => imageFile(hash, ext).existsSync();

  Set<String> listImageHashes() {
    if (!imagesDir.existsSync()) return <String>{};
    final out = <String>{};
    for (final f in imagesDir.listSync().whereType<File>()) {
      final hash = p.basename(f.path).split('.').first;
      // 必须是 64 位十六进制才算内容哈希。
      // 只按 length == 64 判定是不够的：名为 'zzz...z'(64 个非 hex 字符) 的文件
      // 会被误认成哈希，进而被 GC 当作孤儿图片删除。
      if (isContentHash(hash)) out.add(hash);
    }
    return out;
  }

  /// 列出可用备份，按时间倒序。
  List<File> listBackups() {
    if (!backupsDir.existsSync()) return <File>[];
    final files = backupsDir
        .listSync()
        .whereType<File>()
        .where((f) => p.basename(f.path).endsWith('.db'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  /// 保留策略：7 日 + 4 周（变更 1 的对冲要求）。
  ///
  /// 删除超出保留期的每日备份，返回删除数量。
  Future<int> pruneBackups({DateTime? now}) async {
    final t = now ?? DateTime.now();
    final backups = listBackups();
    var removed = 0;
    for (final f in backups) {
      final date = _dateFromBackupName(p.basename(f.path));
      if (date == null) continue;
      final ageDays = t.difference(date).inDays;
      // 7 天内每天保留；再往前只保留「每周一」的备份，最多 4 周。
      final keepDaily = ageDays < 7;
      final keepWeekly = ageDays < 35 && date.weekday == DateTime.monday;
      if (!keepDaily && !keepWeekly) {
        await f.delete();
        removed++;
      }
    }
    return removed;
  }

  static DateTime? _dateFromBackupName(String name) {
    final m = RegExp(r'notes_(\d{4})-(\d{2})-(\d{2})\.db$').firstMatch(name);
    if (m == null) return null;
    return DateTime(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
    );
  }

  static String _2(int n) => n.toString().padLeft(2, '0');
}

/// 判断字符串是否是合法的内容哈希。
bool isContentHash(String value) => _contentHashPattern.hasMatch(value);
