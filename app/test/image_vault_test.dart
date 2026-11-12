import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/db/paths.dart';
import 'package:lan_notepad/src/images/image_vault.dart';
import 'package:notepad_core/notepad_core.dart';
import 'package:path/path.dart' as p;

/// `ImageVault`（变更 1 后改用 `VaultPaths2`）单元测试。
///
/// 关键变化：`collectGarbage({required Set<String> referencedHashes})` ——
/// 引用来源从「扫描 md 文件」改为「调用方从数据库的 image_hashes 列读出来传进来」。
void main() {
  const h64 =
      'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2';

  late Directory tmp;
  late VaultPaths2 paths;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('image_vault_test');
    paths = VaultPaths2.at(Directory(p.join(tmp.path, 'notepad')));
    await paths.ensureLayout();
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 压缩关闭 —— 只验证哈希、内容寻址、去重、GC 这些核心逻辑。
  ImageVault raw() => ImageVault(paths, enabled: false);

  Uint8List bytes(int seed, [int len = 500]) =>
      Uint8List.fromList(List<int>.generate(len, (i) => (i * seed) & 0xff));

  List<String> imageFiles() => paths.imagesDir
      .listSync()
      .whereType<File>()
      .map((f) => p.basename(f.path))
      .toList()
    ..sort();

  group('导入：压缩关闭时的哈希与内容寻址', () {
    test('文件名 = sha256.ext，且哈希与内容一致', () async {
      final data = bytes(3);
      final r = await raw().import(data, '.png');

      expect(r.hash, Hashing.sha256Hex(data));
      expect(r.hash.length, 64);
      expect(r.ext, 'png');
      expect(File(p.join(paths.imagesDir.path, '${r.hash}.png')).existsSync(), isTrue);
      expect(imageFiles(), <String>['${r.hash}.png']);
    });

    test('落盘字节与源字节一致（压缩关闭）', () async {
      final data = bytes(5);
      final r = await raw().import(data, '.jpg');
      final stored = paths.imageFile(r.hash, r.ext).readAsBytesSync();
      expect(stored, data);
      expect(Hashing.matchesSha256(stored, r.hash), isTrue);
    });

    test('返回的 relativeRef 形如 assets/images/<hash>.<ext> 且通过安全校验', () async {
      final r = await raw().import(bytes(5), '.jpg');
      expect(r.relativeRef, 'assets/images/${r.hash}.jpg');
      expect(VaultPaths.validateImageRef(r.relativeRef), isNull);
    });

    test('引用能被 MarkdownDoc 解析回同一哈希（往返一致）', () async {
      final r = await raw().import(bytes(7), '.png');
      expect(MarkdownDoc.extractImageHashes('![图](${r.relativeRef})'), <String>[r.hash]);
    });

    test('扩展名归一化：带点/不带点/大写/jpeg→jpg', () async {
      expect((await raw().import(bytes(3), '.PNG')).ext, 'png');
      expect((await raw().import(bytes(4), 'png')).ext, 'png');
      expect((await raw().import(bytes(6), '.JPEG')).ext, 'jpg');
      expect((await raw().import(bytes(8), '.Webp')).ext, 'webp');
    });

    test('扩展名为空时兜底成 jpg', () async {
      final r = await raw().import(bytes(9), '');
      expect(r.ext, 'jpg');
    });

    test('importFile 从文件导入，哈希与内容对得上', () async {
      final src = File(p.join(tmp.path, 'src.png'))..writeAsBytesSync(bytes(11));
      final r = await raw().importFile(src);
      expect(r.hash, Hashing.sha256Hex(bytes(11)));
      expect(paths.imageFile(r.hash, 'png').existsSync(), isTrue);
    });

    test('内容不同 → 哈希不同，各存一份', () async {
      final a = await raw().import(bytes(2), '.png');
      final b = await raw().import(bytes(3), '.png');
      expect(a.hash, isNot(b.hash));
      expect(imageFiles().length, 2);
    });

    test('大于 128KB 的内容也能正确落盘（跨分块）', () async {
      final big = bytes(13, 300 * 1024);
      final r = await raw().import(big, '.jpg');
      expect(r.hash, Hashing.sha256Hex(big));
      expect(
        Hashing.matchesSha256(paths.imageFile(r.hash, r.ext).readAsBytesSync(), r.hash),
        isTrue,
      );
    });

    test('图片目录不存在时导入会自动创建目录', () async {
      final fresh = VaultPaths2.at(Directory(p.join(tmp.path, 'fresh')));
      final r = await ImageVault(fresh, enabled: false).import(bytes(3), '.png');
      expect(fresh.imageFile(r.hash, 'png').existsSync(), isTrue);
    });
  });

  group('同一图片重复导入只存一份（内容寻址去重）', () {
    test('第二次命中已有文件 → deduplicated=true，磁盘只有一个文件', () async {
      final data = bytes(11);
      final first = await raw().import(data, '.png');
      final second = await raw().import(data, '.png');

      expect(second.hash, first.hash);
      expect(first.deduplicated, isFalse, reason: '首次应真正落盘');
      expect(second.deduplicated, isTrue, reason: '第二次应命中已有文件');
      expect(imageFiles().length, 1);
    });

    test('去重时不会重写文件（mtime 不变）', () async {
      final data = bytes(17);
      final r = await raw().import(data, '.png');
      final f = paths.imageFile(r.hash, r.ext);
      final mtime = f.lastModifiedSync();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      final again = await raw().import(data, '.png');

      expect(again.deduplicated, isTrue);
      expect(f.lastModifiedSync(), mtime);
    });

    test('三次导入同一张图仍然只有一份', () async {
      final data = bytes(19);
      for (var i = 0; i < 3; i++) {
        await raw().import(data, '.png');
      }
      expect(imageFiles().length, 1);
    });

    test('不同扩展名但内容相同 → 哈希相同，会各存一份（文件名不同）', () async {
      final data = bytes(23);
      final a = await raw().import(data, '.png');
      final b = await raw().import(data, '.jpg');
      expect(a.hash, b.hash);
      expect(imageFiles().length, 2,
          reason: '内容寻址按 <hash>.<ext> 命名，扩展名不同就是两个文件');
    });
  });

  group('GC：引用集合里的保留、不在的删除', () {
    test('被引用的保留、未被引用的删除，返回删除数', () async {
      final kept = await raw().import(bytes(31), '.png');
      final orphan = await raw().import(bytes(37), '.png');

      final removed = await raw().collectGarbage(
        referencedHashes: <String>{kept.hash},
      );

      expect(removed, 1);
      expect(paths.imageExists(kept.hash, kept.ext), isTrue, reason: '被引用不能删');
      expect(paths.imageExists(orphan.hash, orphan.ext), isFalse, reason: '孤儿应删');
    });

    test('引用集合为空 → 删除所有图片', () async {
      await raw().import(bytes(41), '.png');
      await raw().import(bytes(43), '.png');
      expect(await raw().collectGarbage(referencedHashes: <String>{}), 2);
      expect(imageFiles(), isEmpty);
    });

    test('引用集合包含不存在的哈希 → 安全（不多删也不少删）', () async {
      final img = await raw().import(bytes(47), '.png');
      final removed = await raw().collectGarbage(
        referencedHashes: <String>{img.hash, h64, '不存在'},
      );
      expect(removed, 0);
      expect(paths.imageExists(img.hash, img.ext), isTrue);
    });

    test('图片目录为空时 GC 返回 0', () async {
      expect(await raw().collectGarbage(referencedHashes: <String>{h64}), 0);
    });

    test('图片目录不存在时 GC 返回 0 而不抛异常', () async {
      final fresh = VaultPaths2.at(Directory(p.join(tmp.path, 'never')));
      expect(
        await ImageVault(fresh, enabled: false)
            .collectGarbage(referencedHashes: <String>{h64}),
        0,
      );
    });

    test('引用集合里的哈希但文件是别的扩展名 → 仍然保留', () async {
      final img = await raw().import(bytes(53), '.webp');
      final removed = await raw().collectGarbage(
        referencedHashes: <String>{img.hash},
      );
      expect(removed, 0);
      expect(paths.imageExists(img.hash, 'webp'), isTrue);
    });

    test('多张图只保留被引用的那一张', () async {
      final a = await raw().import(bytes(59), '.png');
      final b = await raw().import(bytes(61), '.png');
      final c = await raw().import(bytes(67), '.png');

      expect(
        await raw().collectGarbage(referencedHashes: <String>{b.hash}),
        2,
      );
      expect(paths.imageExists(b.hash, b.ext), isTrue);
      expect(paths.imageExists(a.hash, a.ext), isFalse);
      expect(paths.imageExists(c.hash, c.ext), isFalse);
    });

    test('GC 幂等：第二次再跑返回 0', () async {
      await raw().import(bytes(71), '.png');
      expect(await raw().collectGarbage(referencedHashes: <String>{}), 1);
      expect(await raw().collectGarbage(referencedHashes: <String>{}), 0);
    });

    test('被引用的图片 GC 后仍可正常读取', () async {
      final img = await raw().import(bytes(73), '.png');
      await raw().collectGarbage(referencedHashes: <String>{img.hash});
      expect(
        Hashing.matchesSha256(
          paths.imageFile(img.hash, img.ext).readAsBytesSync(),
          img.hash,
        ),
        isTrue,
      );
    });
  });

  group('GC 的安全性：不误删非图片文件', () {
    test('非 64 位哈希命名的文件不被 GC 误删', () async {
      final stray = File(p.join(paths.imagesDir.path, 'readme.txt'))
        ..writeAsStringSync('x');
      final short = File(p.join(paths.imagesDir.path, 'short.png'))
        ..writeAsBytesSync(<int>[1]);
      final long = File(p.join(paths.imagesDir.path, '${'a' * 65}.png'))
        ..writeAsBytesSync(<int>[1]);

      final removed = await raw().collectGarbage(referencedHashes: <String>{});

      expect(removed, 0);
      expect(stray.existsSync(), isTrue);
      expect(short.existsSync(), isTrue);
      expect(long.existsSync(), isTrue);
    });

    test('子目录不会被 GC 递归删除', () async {
      final sub = Directory(p.join(paths.imagesDir.path, 'sub'))
        ..createSync(recursive: true);
      final inSub = File(p.join(sub.path, '$h64.png'))..writeAsBytesSync(<int>[1]);
      await raw().collectGarbage(referencedHashes: <String>{});
      expect(sub.existsSync(), isTrue);
      expect(inSub.existsSync(), isTrue, reason: 'GC 只遍历顶层文件');
    });

    test('GC 不误删「64 字符但非十六进制」的文件（防误删）', () async {
      // 早期实现只判 hash.length == 64，'z' * 64 这种名字会被当成哈希文件删掉。
      // 现在收紧为 ^[0-9a-f]{64}$，它应当被保留。
      final notHex = File(p.join(paths.imagesDir.path, '${'z' * 64}.png'))
        ..writeAsBytesSync(<int>[1]);
      final removed = await raw().collectGarbage(referencedHashes: <String>{});
      expect(removed, 0, reason: '非哈希命名的文件不该被 GC');
      expect(notHex.existsSync(), isTrue);

      // 对照：真正的孤儿哈希文件仍要被删
      const realHash =
          'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
      final orphan = File(p.join(paths.imagesDir.path, '$realHash.png'))
        ..writeAsBytesSync(<int>[2]);
      final removed2 = await raw().collectGarbage(referencedHashes: <String>{});
      expect(removed2, 1);
      expect(orphan.existsSync(), isFalse);
    });
  });

  group('theme/ 目录与 GC 隔离（需求禁止项）', () {
    test('theme/ 下的文件在 GC 后仍在（背景图豁免）', () async {
      final bg = File(p.join(paths.themeDir.path, 'background.jpg'))
        ..writeAsBytesSync(bytes(53));
      final alsoHashNamed = File(p.join(paths.themeDir.path, '$h64.jpg'))
        ..writeAsBytesSync(bytes(57));

      final removed = await raw().collectGarbage(referencedHashes: <String>{});

      expect(removed, 0);
      expect(bg.existsSync(), isTrue, reason: '背景图不在 assets/images，不该被 GC');
      expect(alsoHashNamed.existsSync(), isTrue);
    });

    test('theme/ 里的背景图不参与图片 GC，也不影响 assets/images 的清理', () async {
      final orphan = await raw().import(bytes(63), '.png');
      File(p.join(paths.themeDir.path, 'bg.png')).writeAsBytesSync(bytes(61));

      expect(await raw().collectGarbage(referencedHashes: <String>{}), 1);
      expect(paths.imageExists(orphan.hash, orphan.ext), isFalse);
      expect(File(p.join(paths.themeDir.path, 'bg.png')).existsSync(), isTrue);
    });

    test('theme/ 里的文件不会被 listImageHashes 当成笔记图片', () {
      File(p.join(paths.themeDir.path, '$h64.jpg')).writeAsBytesSync(<int>[1]);
      expect(paths.listImageHashes(), isEmpty);
    });

    test('backups/ 与 exports/ 里的文件同样不受 GC 影响', () async {
      final b = File(p.join(paths.backupsDir.path, '$h64.db'))..writeAsStringSync('x');
      final e = File(p.join(paths.exportsDir.path, '$h64.png'))
        ..writeAsBytesSync(<int>[1]);
      await raw().collectGarbage(referencedHashes: <String>{});
      expect(b.existsSync(), isTrue);
      expect(e.existsSync(), isTrue);
    });
  });

  group('storeReceived：必须校验 SHA-256', () {
    test('哈希匹配 → 落盘成功', () async {
      final data = bytes(79);
      final hash = Hashing.sha256Hex(data);
      expect(await raw().storeReceived(hash, 'png', data), isTrue);
      expect(paths.imageExists(hash, 'png'), isTrue);
      expect(paths.imageFile(hash, 'png').readAsBytesSync(), data);
    });

    test('哈希不匹配 → 拒绝落盘（防投毒），且不留下任何文件', () async {
      final data = bytes(83);
      final wrongHash = 'f' * 64;
      expect(await raw().storeReceived(wrongHash, 'png', data), isFalse);
      expect(paths.imageExists(wrongHash, 'png'), isFalse);
      expect(imageFiles(), isEmpty);
    });

    test('内容被篡改一字节也拒绝', () async {
      final data = bytes(89);
      final hash = Hashing.sha256Hex(data);
      final tampered = Uint8List.fromList(data)..[0] = (data[0] + 1) & 0xff;
      expect(await raw().storeReceived(hash, 'png', tampered), isFalse);
      expect(paths.imageExists(hash, 'png'), isFalse);
    });

    test('大小写不同但内容相同的哈希 → 匹配成功（大小写不敏感）', () async {
      final data = bytes(97);
      final hash = Hashing.sha256Hex(data);
      expect(await raw().storeReceived(hash.toUpperCase(), 'png', data), isTrue);
    });

    test('已存在则跳过写入（mtime 不变）', () async {
      final data = bytes(101);
      final hash = Hashing.sha256Hex(data);
      await raw().storeReceived(hash, 'png', data);
      final f = paths.imageFile(hash, 'png');
      final mtime = f.lastModifiedSync();

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await raw().storeReceived(hash, 'png', data), isTrue);
      expect(f.lastModifiedSync(), mtime);
    });

    test('拒绝的图片不会污染已有文件', () async {
      final good = bytes(103);
      final hash = Hashing.sha256Hex(good);
      await raw().storeReceived(hash, 'png', good);
      final before = paths.imageFile(hash, 'png').readAsBytesSync();

      expect(await raw().storeReceived(hash, 'png', bytes(107)), isFalse);
      expect(paths.imageFile(hash, 'png').readAsBytesSync(), before);
    });

    test('接收到的图片能被 MarkdownDoc 反解回哈希', () async {
      final data = bytes(109);
      final hash = Hashing.sha256Hex(data);
      await raw().storeReceived(hash, 'jpg', data);
      expect(
        MarkdownDoc.extractImageHashes(
          '![图](${VaultPaths.imageRef(hash, 'jpg')})',
        ),
        <String>[hash],
      );
    });

    test('接收的图片随后被 GC 保护（在引用集合里）', () async {
      final data = bytes(113);
      final hash = Hashing.sha256Hex(data);
      await raw().storeReceived(hash, 'png', data);
      expect(await raw().collectGarbage(referencedHashes: <String>{hash}), 0);
      expect(paths.imageExists(hash, 'png'), isTrue);
    });
  });

  group('压缩开关', () {
    test('压缩开启时平台通道不可用也不阻断导入（回退原图）', () async {
      // 单元测试环境没有 FlutterImageCompress 的平台通道，
      // 实现里应捕获异常并回退为原图，而不是让导入失败。
      final data = bytes(127, 2048);
      final r = await ImageVault(paths, enabled: true).import(data, '.png');

      expect(r.hash, Hashing.sha256Hex(r.bytes));
      expect(paths.imageExists(r.hash, r.ext), isTrue);
      // 回退原图 → 内容与源一致
      expect(paths.imageFile(r.hash, r.ext).readAsBytesSync(), data);
    });

    test('压缩开启时返回的 bytes 与落盘内容一致', () async {
      final data = bytes(131, 4096);
      final r = await ImageVault(paths, enabled: true).import(data, '.jpg');
      expect(
        Hashing.matchesSha256(
          paths.imageFile(r.hash, r.ext).readAsBytesSync(),
          r.hash,
        ),
        isTrue,
      );
    });

    test('默认构造（enabled 默认 true）不会抛异常', () async {
      final r = await ImageVault(paths).import(bytes(137, 1024), '.png');
      expect(r.hash.length, 64);
    });
  });
}
