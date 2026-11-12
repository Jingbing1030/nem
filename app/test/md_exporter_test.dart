import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/db/database.dart';
import 'package:lan_notepad/src/db/paths.dart';
import 'package:lan_notepad/src/export/md_exporter.dart';
import 'package:notepad_core/notepad_core.dart';
import 'package:path/path.dart' as p;

/// `MdExporter`（变更 8）单元测试。
///
/// 关键验收项：**导出产物必须可独立使用** —— md 里引用的图片要被复制到
/// `<导出目录>/assets/images/` 下。
void main() {
  const h1 =
      '1111111111111111111111111111111111111111111111111111111111111111';
  const h2 =
      '2222222222222222222222222222222222222222222222222222222222222222';

  late Directory tmp;
  late AppDatabase db;
  late VaultPaths2 paths;
  late MdExporter exporter;
  final t0 = DateTime.utc(2026, 11, 12, 10, 0, 0);

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('md_exporter_test');
    paths = VaultPaths2.at(Directory(p.join(tmp.path, 'notepad')));
    await paths.ensureLayout();
    db = AppDatabase.atFile(File(p.join(tmp.path, 'notes.db')));
    exporter = MdExporter(db, paths);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 往库里塞一篇笔记。
  Future<void> put(
    String noteId,
    String title,
    String content, {
    bool isDeleted = false,
    int updatedOffsetMinutes = 0,
  }) =>
      db.upsertNote(
        noteId: noteId,
        title: title,
        content: content,
        excerpt: content,
        versionVector: '{"dev-A":1}',
        contentHash: Hashing.contentHash(content),
        imageHashesJson: '[]',
        createdAt: t0,
        updatedAt: t0.add(Duration(minutes: updatedOffsetMinutes)),
        isDeleted: isDeleted,
      );

  /// 假图片：写进笔记库的 assets/images。
  File putImage(String hash, String ext, [List<int>? bytes]) {
    final f = paths.imageFile(hash, ext);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes ?? <int>[1, 2, 3, 4, 5]);
    return f;
  }

  Directory exportDir() =>
      Directory(p.join(tmp.path, 'export-out'));

  group('exportAll 基本行为', () {
    test('文件名格式为 <title>_<noteId>.md，内容与库中一致', () async {
      const content = '# 我的标题\n\n正文第一行\n\n正文第二行';
      await put('note-1234', '我的标题', content);

      final r = await exporter.exportAll(targetDir: exportDir());

      expect(r.files, 1);
      final f = File(p.join(exportDir().path, '我的标题_note-1234.md'));
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), content);
      expect(r.targetDir, exportDir().path);
    });

    test('默认导出到 paths.exportsDir', () async {
      await put('n1', '标题', '正文');
      final r = await exporter.exportAll();
      expect(r.targetDir, paths.exportsDir.path);
      expect(
        File(p.join(paths.exportsDir.path, '标题_n1.md')).existsSync(),
        isTrue,
      );
    });

    test('多篇笔记全部导出，文件名互不冲突', () async {
      await put('id-a', '甲', 'AAA', updatedOffsetMinutes: 1);
      await put('id-b', '乙', 'BBB', updatedOffsetMinutes: 2);
      await put('id-c', '丙', 'CCC', updatedOffsetMinutes: 3);

      final r = await exporter.exportAll(targetDir: exportDir());

      expect(r.files, 3);
      expect(exportDir().listSync().whereType<File>().length, 3);
      expect(File(p.join(exportDir().path, '甲_id-a.md')).readAsStringSync(), 'AAA');
      expect(File(p.join(exportDir().path, '乙_id-b.md')).readAsStringSync(), 'BBB');
      expect(File(p.join(exportDir().path, '丙_id-c.md')).readAsStringSync(), 'CCC');
    });

    test('墓碑（已删除的笔记）不导出', () async {
      await put('live', '活着的', '正文');
      await put('dead', '死掉的', '', isDeleted: true, updatedOffsetMinutes: 5);

      final r = await exporter.exportAll(targetDir: exportDir());

      expect(r.files, 1);
      expect(
        exportDir().listSync().whereType<File>().map((f) => p.basename(f.path)),
        <String>['活着的_live.md'],
      );
    });

    test('空库导出 0 篇且不报错，目录会被创建', () async {
      final r = await exporter.exportAll(targetDir: exportDir());
      expect(r.files, 0);
      expect(r.imagesCopied, 0);
      expect(exportDir().existsSync(), isTrue);
    });

    test('导出目录不存在时自动递归创建', () async {
      await put('n1', 'T', 'c');
      final deep = Directory(p.join(tmp.path, 'x', 'y', 'z'));
      await exporter.exportAll(targetDir: deep);
      expect(deep.existsSync(), isTrue);
    });

    test('同标题不同 noteId 的两篇不会互相覆盖', () async {
      await put('id-1', '同名', '第一篇', updatedOffsetMinutes: 1);
      await put('id-2', '同名', '第二篇', updatedOffsetMinutes: 2);
      await exporter.exportAll(targetDir: exportDir());
      expect(
        File(p.join(exportDir().path, '同名_id-1.md')).readAsStringSync(),
        '第一篇',
      );
      expect(
        File(p.join(exportDir().path, '同名_id-2.md')).readAsStringSync(),
        '第二篇',
      );
    });

    test('重复导出会刷新内容（内容改了，md 跟着改）', () async {
      await put('n1', '标题', '第一版');
      await exporter.exportAll(targetDir: exportDir());
      await put('n1', '标题', '第二版', updatedOffsetMinutes: 9);
      await exporter.exportAll(targetDir: exportDir());
      expect(
        File(p.join(exportDir().path, '标题_n1.md')).readAsStringSync(),
        '第二版',
      );
    });
  });

  group('图片复制（关键验收：导出产物可独立使用）', () {
    test('正文引用的图片被复制到 <导出目录>/assets/images/', () async {
      final src = putImage(h1, 'png');
      await put('n1', '带图', '![图](assets/images/$h1.png)');

      final r = await exporter.exportAll(targetDir: exportDir());

      expect(r.imagesCopied, 1);
      final dest = File(p.join(exportDir().path, 'assets', 'images', '$h1.png'));
      expect(dest.existsSync(), isTrue, reason: '图片必须被复制过去');
      // 字节完全一致
      expect(dest.readAsBytesSync(), src.readAsBytesSync());
    });

    test('导出目录里 md 的相对引用能真的解析到文件（独立可用）', () async {
      putImage(h1, 'png');
      const content = '# 图\n\n![图](assets/images/$h1.png)';
      await put('n1', '图', content);

      await exporter.exportAll(targetDir: exportDir());

      // 模拟「把导出目录单独拷到别处」：按 md 里的相对路径拼绝对路径
      final refPaths = MarkdownDoc.extractImagePaths(content);
      expect(refPaths, <String>['assets/images/$h1.png']);
      for (final ref in refPaths) {
        final f = File(p.join(exportDir().path, ref));
        expect(f.existsSync(), isTrue, reason: '相对引用 $ref 应能解析到文件');
      }
    });

    test('多篇笔记引用同一张图 → 只复制一份', () async {
      putImage(h1, 'png');
      await put('n1', 'A', '![图](assets/images/$h1.png)', updatedOffsetMinutes: 1);
      await put('n2', 'B', '![另一处](assets/images/$h1.png)', updatedOffsetMinutes: 2);

      final r = await exporter.exportAll(targetDir: exportDir());

      expect(r.files, 2);
      expect(r.imagesCopied, 1);
      expect(
        Directory(p.join(exportDir().path, 'assets', 'images'))
            .listSync()
            .whereType<File>()
            .length,
        1,
      );
    });

    test('多张不同图片都被复制', () async {
      putImage(h1, 'png');
      putImage(h2, 'jpg');
      await put('n1', '两张', '![a](assets/images/$h1.png)\n![b](assets/images/$h2.jpg)');

      final r = await exporter.exportAll(targetDir: exportDir());

      expect(r.imagesCopied, 2);
      expect(
        File(p.join(exportDir().path, 'assets', 'images', '$h1.png')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(exportDir().path, 'assets', 'images', '$h2.jpg')).existsSync(),
        isTrue,
      );
    });

    test('正文引用了但库里没有的图片 → 跳过，不抛异常', () async {
      await put('n1', '缺图', '![a](assets/images/$h1.png)');
      final r = await exporter.exportAll(targetDir: exportDir());
      expect(r.files, 1);
      expect(r.imagesCopied, 0);
      // 实现只要 body 里有图片引用就会先建出 assets/images/（即目录可能为空）
      expect(Directory(p.join(exportDir().path, 'assets', 'images')).existsSync(),
          isTrue);
      expect(
        Directory(p.join(exportDir().path, 'assets', 'images'))
            .listSync()
            .whereType<File>(),
        isEmpty,
      );
    });

    test('外链图片不产生本地复制', () async {
      await put('n1', '外链', '![a](https://example.com/a.png)');
      final r = await exporter.exportAll(targetDir: exportDir());
      expect(r.imagesCopied, 0);
    });

    test('没有图片的笔记 imagesCopied 为 0', () async {
      await put('n1', '纯文字', '没有图片');
      expect((await exporter.exportAll(targetDir: exportDir())).imagesCopied, 0);
    });

    test('扩展名不同但哈希相同的图片按实际文件复制', () async {
      putImage(h1, 'webp', <int>[7, 7, 7]);
      await put('n1', 'webp 图', '![a](assets/images/$h1.webp)');
      final r = await exporter.exportAll(targetDir: exportDir());
      expect(r.imagesCopied, 1);
      expect(
        File(p.join(exportDir().path, 'assets', 'images', '$h1.webp'))
            .readAsBytesSync(),
        <int>[7, 7, 7],
      );
    });
  });

  group('导出幂等', () {
    test('重复导出不重复复制图片（第二次 imagesCopied = 0）', () async {
      putImage(h1, 'png');
      await put('n1', '带图', '![图](assets/images/$h1.png)');

      final first = await exporter.exportAll(targetDir: exportDir());
      final second = await exporter.exportAll(targetDir: exportDir());

      expect(first.imagesCopied, 1);
      expect(second.imagesCopied, 0, reason: '已存在且大小一致 → 跳过');
      expect(
        Directory(p.join(exportDir().path, 'assets', 'images'))
            .listSync()
            .whereType<File>()
            .length,
        1,
      );
    });

    test('重复导出 md 文件数不增长', () async {
      putImage(h1, 'png');
      await put('n1', 'T', '![图](assets/images/$h1.png)');
      await exporter.exportAll(targetDir: exportDir());
      await exporter.exportAll(targetDir: exportDir());
      await exporter.exportAll(targetDir: exportDir());
      expect(exportDir().listSync().whereType<File>().length, 1);
    });

    test('源图片内容变了（同文件名不同大小）→ 重新复制', () async {
      putImage(h1, 'png', <int>[1, 2, 3]);
      await put('n1', 'T', '![图](assets/images/$h1.png)');
      await exporter.exportAll(targetDir: exportDir());

      // 内容寻址理论上不会变，但这里直接测「大小不一致就重拷」这条分支
      putImage(h1, 'png', <int>[1, 2, 3, 4, 5, 6, 7]);
      final second = await exporter.exportAll(targetDir: exportDir());

      expect(second.imagesCopied, 1);
      expect(
        File(p.join(exportDir().path, 'assets', 'images', '$h1.png'))
            .readAsBytesSync(),
        <int>[1, 2, 3, 4, 5, 6, 7],
      );
    });

    test('导出幂等：md 内容也不变', () async {
      await put('n1', 'T', '内容 X');
      await exporter.exportAll(targetDir: exportDir());
      final a = File(p.join(exportDir().path, 'T_n1.md')).readAsStringSync();
      await exporter.exportAll(targetDir: exportDir());
      final b = File(p.join(exportDir().path, 'T_n1.md')).readAsStringSync();
      expect(a, b);
    });
  });

  group('标题非法字符安全化', () {
    test('把 / : * ? " < > | 替换成下划线', () async {
      await put('n1', r'a/b:c*d?e"f<g>h|i', '正文');
      await exporter.exportAll(targetDir: exportDir());

      final names = exportDir()
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .toList();
      expect(names.length, 1);
      expect(names.single, 'a_b_c_d_e_f_g_h_i_n1.md');
      expect(names.single.contains('/'), isFalse);
      expect(names.single.contains(':'), isFalse);
    });

    test('反斜杠与控制字符也被替换（不会写坏文件系统）', () async {
      await put('n1', 'tab\there\\and', '正文');
      await exporter.exportAll(targetDir: exportDir());
      final name = exportDir()
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .single;
      expect(name.contains('\\'), isFalse);
      expect(name.contains('\t'), isFalse);
      expect(name, 'tab_here_and_n1.md');
    });

    test('标题两端的空白被去掉', () async {
      await put('n1', '  标题  ', '正文');
      await exporter.exportAll(targetDir: exportDir());
      expect(
        File(p.join(exportDir().path, '标题_n1.md')).existsSync(),
        isTrue,
      );
    });

    test('标题里的连续空白压成一个空格', () async {
      await put('n1', '很   多     空格', '正文');
      await exporter.exportAll(targetDir: exportDir());
      expect(
        File(p.join(exportDir().path, '很 多 空格_n1.md')).existsSync(),
        isTrue,
      );
    });

    test('超长标题被截断到 80 字以内（不超文件系统上限）', () async {
      final long = '长' * 200;
      await put('n1', long, '正文');
      await exporter.exportAll(targetDir: exportDir());
      final base = p.basenameWithoutExtension(
        exportDir().listSync().whereType<File>().single.path,
      );
      // 截断后 + '_n1'
      expect(base.length, 80 + 3);
      expect(base.endsWith('_n1'), isTrue);
    });
  });

  group('空标题 → 「未命名」', () {
    test('标题为空串时文件名用「未命名」', () async {
      await put('n1', '', '正文');
      await exporter.exportAll(targetDir: exportDir());
      expect(
        File(p.join(exportDir().path, '未命名_n1.md')).existsSync(),
        isTrue,
      );
    });

    test('标题只有空白也用「未命名」', () async {
      await put('n1', '   \t ', '正文');
      await exporter.exportAll(targetDir: exportDir());
      expect(
        File(p.join(exportDir().path, '未命名_n1.md')).existsSync(),
        isTrue,
      );
    });

    test('两篇都空标题时靠 noteId 区分，不互相覆盖', () async {
      await put('id-a', '', 'A', updatedOffsetMinutes: 1);
      await put('id-b', '', 'B', updatedOffsetMinutes: 2);
      await exporter.exportAll(targetDir: exportDir());
      expect(File(p.join(exportDir().path, '未命名_id-a.md')).readAsStringSync(), 'A');
      expect(File(p.join(exportDir().path, '未命名_id-b.md')).readAsStringSync(), 'B');
    });
  });

  group('exportOne 单篇导出', () {
    test('只导出指定的一篇，其余不落盘', () async {
      putImage(h1, 'png');
      await put('id-a', '甲', 'AAA', updatedOffsetMinutes: 1);
      await put('id-b', '乙', '![图](assets/images/$h1.png)', updatedOffsetMinutes: 2);

      final r = await exporter.exportOne('id-b', targetDir: exportDir());

      expect(r.files, 1);
      expect(r.imagesCopied, 1);
      expect(File(p.join(exportDir().path, '乙_id-b.md')).existsSync(), isTrue);
      expect(File(p.join(exportDir().path, '甲_id-a.md')).existsSync(), isFalse);
    });

    test('noteId 不存在 → files 0，不抛异常', () async {
      final r = await exporter.exportOne('不存在', targetDir: exportDir());
      expect(r.files, 0);
      expect(r.imagesCopied, 0);
    });

    test('墓碑不会被单篇导出出正文', () async {
      await put('dead', '已删', '', isDeleted: true);
      final r = await exporter.exportOne('dead', targetDir: exportDir());
      // 实现只判 noteById 是否为 null，墓碑会导出成空文件；
      // 钉住现状：至少不能导出到原正文（content 已被清空）。
      expect(r.files, 1);
      expect(
        File(p.join(exportDir().path, '已删_dead.md')).readAsStringSync(),
        '',
      );
    });

    test('exportOne 的图片复制同样幂等', () async {
      putImage(h1, 'png');
      await put('n1', 'T', '![图](assets/images/$h1.png)');
      expect((await exporter.exportOne('n1', targetDir: exportDir())).imagesCopied, 1);
      expect((await exporter.exportOne('n1', targetDir: exportDir())).imagesCopied, 0);
    });
  });

  group('ExportResult.toString 可读', () {
    test('包含篇数与图片数', () async {
      await put('n1', 'T', 'c');
      final r = await exporter.exportAll(targetDir: exportDir());
      expect(r.toString(), contains('1 篇'));
      expect(r.toString(), contains('0 张图片'));
    });
  });
}
