import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/db/paths.dart';
import 'package:notepad_core/notepad_core.dart';
import 'package:path/path.dart' as p;

/// `VaultPaths2`（变更 1 的新目录布局）单元测试。
///
/// 覆盖：目录结构、ensureLayout 幂等、内容寻址图片、备份文件命名与保留策略、
/// 以及「theme/ 与 assets/images 互相隔离」这条需求禁止项。
void main() {
  const h64 =
      'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2';

  late Directory tmp;
  late VaultPaths2 v;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('vault_paths_test');
    v = VaultPaths2.at(Directory(p.join(tmp.path, 'notepad')));
    await v.ensureLayout();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('目录布局（变更 1）', () {
    test('根目录下是 notes.db + backups/ exports/ assets/images/ theme/', () {
      expect(v.dbFile.path, p.join(v.root.path, 'notes.db'));

      expect(v.backupsDir.existsSync(), isTrue);
      expect(v.exportsDir.existsSync(), isTrue);
      expect(v.imagesDir.existsSync(), isTrue);
      expect(v.themeDir.existsSync(), isTrue);

      expect(v.backupsDir.path, p.join(v.root.path, 'backups'));
      expect(v.exportsDir.path, p.join(v.root.path, 'exports'));
      expect(v.themeDir.path, p.join(v.root.path, 'theme'));
      expect(p.basename(v.imagesDir.path), 'images');
      expect(p.basename(p.dirname(v.imagesDir.path)), 'assets');
    });

    test('不再有 notes/ 常驻目录（正文已入库）', () {
      final legacy =
          Directory(p.join(v.root.path, VaultPaths.notesDir)); // 'notes'
      expect(legacy.existsSync(), isFalse);
    });

    test('ensureLayout 幂等：重复调用不清空已有内容', () async {
      final img = v.imageFile(h64, 'png')..writeAsBytesSync(<int>[1, 2, 3]);
      await v.ensureLayout();
      await v.ensureLayout();

      expect(img.existsSync(), isTrue);
      expect(img.readAsBytesSync(), <int>[1, 2, 3]);
      expect(v.listImageHashes(), <String>{h64});
    });

    test('根目录不存在时 ensureLayout 会递归创建', () async {
      final nested = VaultPaths2.at(
        Directory(p.join(tmp.path, 'a', 'b', 'notepad')),
      );
      await nested.ensureLayout();
      expect(nested.imagesDir.existsSync(), isTrue);
      expect(nested.backupsDir.existsSync(), isTrue);
      expect(nested.exportsDir.existsSync(), isTrue);
      expect(nested.themeDir.existsSync(), isTrue);
    });
  });

  group('内容寻址图片', () {
    test('imageFile 路径为 assets/images/<hash>.<ext>', () {
      expect(v.imageFile(h64, 'png').path, p.join(v.imagesDir.path, '$h64.png'));
      expect(v.imageFile(h64, 'jpg').path, p.join(v.imagesDir.path, '$h64.jpg'));
    });

    test('扩展名带点或不带点等价', () {
      expect(v.imageFile(h64, '.png').path, v.imageFile(h64, 'png').path);
    });

    test('imageExists 只认真实存在的文件', () {
      expect(v.imageExists(h64, 'png'), isFalse);
      v.imageFile(h64, 'png').writeAsBytesSync(<int>[0]);
      expect(v.imageExists(h64, 'png'), isTrue);
      expect(v.imageExists(h64, 'jpg'), isFalse);
    });

    test('listImageHashes 收集 64 位十六进制文件名', () {
      v.imageFile(h64, 'png').writeAsBytesSync(<int>[1]);
      File(p.join(v.imagesDir.path, 'readme.txt')).writeAsStringSync('x');
      File(p.join(v.imagesDir.path, 'short.png')).writeAsBytesSync(<int>[1]);
      File(p.join(v.imagesDir.path, '${'a' * 63}.png')).writeAsBytesSync(<int>[1]);
      File(p.join(v.imagesDir.path, '${'a' * 65}.png')).writeAsBytesSync(<int>[1]);

      expect(v.listImageHashes(), <String>{h64});
    });

    test('图片目录不存在时 listImageHashes 返回空集合', () {
      final other = VaultPaths2.at(Directory(p.join(tmp.path, 'never-created')));
      expect(other.listImageHashes(), isEmpty);
    });

    test('listImageHashes 只认真正的 64 位十六进制哈希（防误删）', () {
      // 早期实现只判断 hash.length == 64，于是名为 'zzz...z'（64 个非 hex 字符）
      // 的文件会被误认成内容哈希，进而被 GC 当作孤儿图片删除。
      // 现在收紧为 ^[0-9a-f]{64}$。
      final notHash = File(p.join(v.imagesDir.path, '${'z' * 64}.png'))
        ..writeAsBytesSync(<int>[1]);
      expect(v.listImageHashes(), isEmpty, reason: '非十六进制的 64 字符名不算哈希');
      expect(notHash.existsSync(), isTrue);

      // 真正的哈希要被认出来（大小写：实现按小写十六进制判定）
      const realHash =
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
      File(p.join(v.imagesDir.path, '$realHash.png')).writeAsBytesSync(<int>[2]);
      expect(v.listImageHashes(), <String>{realHash});
    });
  });

  group('备份文件命名与列举', () {
    test('dailyBackup 文件名格式 notes_YYYY-MM-DD.db', () {
      final f = v.dailyBackup(DateTime(2026, 11, 12));
      expect(p.basename(f.path), 'notes_2026-11-12.db');
      expect(p.dirname(f.path), v.backupsDir.path);
    });

    test('dailyBackup 月/日补零', () {
      expect(
        p.basename(v.dailyBackup(DateTime(2026, 1, 5)).path),
        'notes_2026-01-05.db',
      );
    });

    test('mdSnapshot 目录名带日期', () {
      expect(
        p.basename(v.mdSnapshot(DateTime(2026, 1, 5)).path),
        'md_snapshot_2026-01-05',
      );
    });

    test('listBackups 只列 .db 且按时间倒序', () {
      for (final d in <DateTime>[
        DateTime(2026, 11, 1),
        DateTime(2026, 11, 12),
        DateTime(2026, 10, 5),
      ]) {
        v.dailyBackup(d).writeAsStringSync('x');
      }
      File(p.join(v.backupsDir.path, 'readme.txt')).writeAsStringSync('x');
      v.mdSnapshot(DateTime(2026, 11, 12)).createSync(recursive: true);

      expect(
        v.listBackups().map((f) => p.basename(f.path)).toList(),
        <String>[
          'notes_2026-11-12.db',
          'notes_2026-11-01.db',
          'notes_2026-10-05.db',
        ],
      );
    });

    test('备份目录不存在时 listBackups 返回空列表', () {
      final other = VaultPaths2.at(Directory(p.join(tmp.path, 'never-created')));
      expect(other.listBackups(), isEmpty);
    });
  });

  group('备份保留策略：7 日 + 4 周', () {
    test('7 天内每天保留；更早只保留周一（不超过 35 天）', () async {
      final now = DateTime(2026, 11, 12); // 周四
      var d = DateTime(2026, 9, 1);
      final all = <DateTime>[];
      while (!d.isAfter(now)) {
        v.dailyBackup(d).writeAsStringSync('x');
        all.add(d);
        d = d.add(const Duration(days: 1));
      }
      expect(all.length, 73, reason: '9/1 ~ 11/12 共 73 天');

      final removed = await v.pruneBackups(now: now);

      // 近 7 天（11-06 ~ 11-12）：全部保留
      for (var day = 6; day <= 12; day++) {
        expect(
          v.dailyBackup(DateTime(2026, 11, day)).existsSync(),
          isTrue,
          reason: '11-$day 在 7 天内，应保留',
        );
      }
      // 7 天前：只有周一且未满 35 天的保留（11-09 已在上面覆盖）
      expect(v.dailyBackup(DateTime(2026, 11, 2)).existsSync(), isTrue,
          reason: '11-02（周一，10 天前）应保留');
      expect(v.dailyBackup(DateTime(2026, 10, 26)).existsSync(), isTrue,
          reason: '10-26（周一，17 天前）应保留');
      expect(v.dailyBackup(DateTime(2026, 10, 19)).existsSync(), isTrue,
          reason: '10-19（周一，24 天前）应保留');
      expect(v.dailyBackup(DateTime(2026, 10, 12)).existsSync(), isTrue,
          reason: '10-12（周一，31 天前）应保留');

      // 第 7 天且非周一 → 删
      expect(v.dailyBackup(DateTime(2026, 11, 5)).existsSync(), isFalse,
          reason: '11-05（周四，恰好 7 天）应删除');
      expect(v.dailyBackup(DateTime(2026, 11, 4)).existsSync(), isFalse);
      // 周一但超过 35 天 → 删
      expect(v.dailyBackup(DateTime(2026, 10, 5)).existsSync(), isFalse,
          reason: '10-05（周一，38 天）超出 4 周应删除');
      expect(v.dailyBackup(DateTime(2026, 9, 28)).existsSync(), isFalse);

      expect(removed, 73 - 11);
      expect(v.listBackups().length, 11);
    });

    test('第二次 pruneBackups 不再删除任何东西（幂等）', () async {
      final now = DateTime(2026, 11, 12);
      var d = DateTime(2026, 10, 1);
      while (!d.isAfter(now)) {
        v.dailyBackup(d).writeAsStringSync('x');
        d = d.add(const Duration(days: 1));
      }
      await v.pruneBackups(now: now);
      final left = v.listBackups().length;
      expect(await v.pruneBackups(now: now), 0);
      expect(v.listBackups().length, left);
    });

    test('名字不合法的文件一律不动', () async {
      final stray = File(p.join(v.backupsDir.path, 'notes_old.db'))
        ..writeAsStringSync('x');
      final manual = File(p.join(v.backupsDir.path, 'manual.db'))
        ..writeAsStringSync('x');
      final txt = File(p.join(v.backupsDir.path, 'readme.txt'))
        ..writeAsStringSync('x');

      final removed = await v.pruneBackups(now: DateTime(2026, 11, 12));

      expect(removed, 0);
      expect(stray.existsSync(), isTrue);
      expect(manual.existsSync(), isTrue);
      expect(txt.existsSync(), isTrue);
    });

    test('没有任何备份时安全返回 0', () async {
      expect(await v.pruneBackups(now: DateTime(2026, 11, 12)), 0);
    });
  });

  group('theme/ 与 assets/images 互相隔离（需求禁止项）', () {
    test('两个目录不同且互不包含', () {
      expect(v.themeDir.path, isNot(v.imagesDir.path));
      expect(p.isWithin(v.root.path, v.themeDir.path), isTrue);
      expect(p.isWithin(v.root.path, v.imagesDir.path), isTrue);
      expect(p.isWithin(v.imagesDir.path, v.themeDir.path), isFalse);
      expect(p.isWithin(v.themeDir.path, v.imagesDir.path), isFalse);
    });

    test('theme/ 下的文件不会被当作笔记图片', () {
      File(p.join(v.themeDir.path, 'background.jpg')).writeAsBytesSync(<int>[9]);
      File(p.join(v.themeDir.path, '$h64.jpg')).writeAsBytesSync(<int>[9]);
      expect(v.listImageHashes(), isEmpty);
      expect(v.imageExists(h64, 'jpg'), isFalse);
    });

    test('imageFile 只会落在 assets/images 下', () {
      final f = v.imageFile(h64, 'png');
      expect(p.isWithin(v.imagesDir.path, f.path), isTrue);
      expect(p.isWithin(v.themeDir.path, f.path), isFalse);
    });

    test('备份目录里的 .db 不会被当成图片资源', () {
      v.dailyBackup(DateTime(2026, 11, 12)).writeAsStringSync('x');
      expect(v.listImageHashes(), isEmpty);
    });
  });
}
