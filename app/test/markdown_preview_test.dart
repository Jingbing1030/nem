import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/db/paths.dart';
import 'package:notepad_core/notepad_core.dart';
import 'package:markdown/markdown.dart' as md_ext;
import 'package:lan_notepad/src/ui/markdown_preview.dart';
import 'package:path/path.dart' as p;

/// `MarkdownPreview` 单元测试。
///
/// 变更 1 后正文入库，但图片仍是 `assets/images/<hash>.<ext>` 文件，
/// 因此 `notesRoot` 的语义不变：**笔记库根目录**（相对引用基于它解析）。
/// 这里按实际实现（`lib/src/ui/markdown_preview.dart`）逐条钉住四种图片情况。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('md_test');
    Directory(p.join(root.path, 'assets', 'images')).createSync(recursive: true);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pump(
    WidgetTester tester,
    String md, {
    void Function(String)? onReimport,
    String? notesRoot,
  }) =>
      tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MarkdownPreview(
              data: md,
              notesRoot: notesRoot ?? root.path,
              onReimport: onReimport,
            ),
          ),
        ),
      ));

  /// 写入一张最小可解码的 PNG（1x1）。
  File writePng(String name, {Directory? dir}) {
    final bytes = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG magic
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41, // IDAT
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, // IEND
      0x42, 0x60, 0x82,
    ];
    final f = File(p.join((dir ?? Directory(p.join(root.path, 'assets', 'images'))).path, name));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return f;
  }

  group('Markdown 渲染', () {
    testWidgets('标题、正文正常渲染', (tester) async {
      await pump(tester, '# 标题\n\n正文段落');
      expect(find.textContaining('标题'), findsWidgets);
      expect(find.textContaining('正文段落'), findsWidgets);
    });

    testWidgets('使用 flutter_markdown_plus 的 MarkdownBody', (tester) async {
      await pump(tester, '普通文本');
      expect(find.byType(MarkdownBody), findsOneWidget);
    });

    testWidgets('表格扩展可用', (tester) async {
      await pump(tester, '| A | B |\n| --- | --- |\n| 1 | 2 |');
      expect(find.byType(MarkdownBody), findsOneWidget);
      expect(find.textContaining('A'), findsWidgets);
    });

    testWidgets('任务列表渲染', (tester) async {
      await pump(tester, '- [x] 已完成\n- [ ] 未完成');
      expect(find.textContaining('已完成'), findsWidgets);
    });

    testWidgets('删除线语法不报错', (tester) async {
      await pump(tester, '~~删除~~');
      expect(tester.takeException(), isNull);
    });

    testWidgets('代码块渲染', (tester) async {
      await pump(tester, '```dart\nvoid main() {}\n```');
      expect(find.textContaining('void main'), findsWidgets);
    });

    testWidgets('extensionSet 用的是 gitHubWeb 扩展集', (tester) async {
      expect(
        identical(MarkdownPreview.extensionSet, md_ext.ExtensionSet.gitHubWeb),
        isTrue,
      );
    });
  });

  group('自定义 imageBuilder（需求 5.2 四种情况）', () {
    testWidgets('相对路径且文件存在 → Image.file', (tester) async {
      final hash = 'a' * 64;
      writePng('$hash.png');
      await pump(tester, '![图](assets/images/$hash.png)');
      await tester.pump();
      expect(find.byType(Image), findsWidgets);
      expect(find.text('图片缺失'), findsNothing);
    });

    testWidgets('相对路径但文件缺失 → 灰色占位 +「图片缺失」', (tester) async {
      final missing = 'b' * 64;
      await pump(tester, '![图](assets/images/$missing.png)');
      expect(find.text('图片缺失'), findsOneWidget);
      expect(find.byType(Icon), findsWidgets);
    });

    testWidgets('缺失且有 onReimport → 出现「重新导入」按钮', (tester) async {
      final missing = 'c' * 64;
      await pump(tester, '![图](assets/images/$missing.png)', onReimport: (_) {});
      expect(find.text('重新导入'), findsOneWidget);
    });

    testWidgets('缺失且没有 onReimport → 不显示按钮', (tester) async {
      final missing = 'd' * 64;
      await pump(tester, '![图](assets/images/$missing.png)');
      expect(find.text('重新导入'), findsNothing);
    });

    testWidgets('点击「重新导入」回调拿到原始相对引用', (tester) async {
      final missing = 'e' * 64;
      String? got;
      await pump(
        tester,
        '![图](assets/images/$missing.png)',
        onReimport: (ref) => got = ref,
      );
      await tester.tap(find.text('重新导入'));
      await tester.pump();
      expect(got, 'assets/images/$missing.png');
    });

    testWidgets('绝对路径存在 → 正常显示（不报缺失）', (tester) async {
      final f = writePng('${'f' * 64}.png');
      await pump(tester, '![图](${f.path})');
      await tester.pump();
      expect(find.text('图片缺失'), findsNothing);
    });

    testWidgets('绝对路径不存在 → 占位提示读取失败', (tester) async {
      await pump(tester, '![图](/nonexistent/path/x.png)');
      expect(find.textContaining('绝对路径读取失败'), findsOneWidget);
    });

    testWidgets('http 外链走 Image.network', (tester) async {
      await pump(tester, '![图](https://example.com/a.png)');
      await tester.pump();
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images.any((i) => i.image is NetworkImage), isTrue);
    });

    testWidgets('缺失图片不影响其余内容渲染', (tester) async {
      final missing = '0' * 64;
      await pump(tester, '# 标题\n\n![图](assets/images/$missing.png)\n\n后面的正文');
      expect(find.textContaining('标题'), findsWidgets);
      expect(find.textContaining('后面的正文'), findsWidgets);
      expect(find.text('图片缺失'), findsOneWidget);
    });
  });

  group('与 VaultPaths2 的真实目录布局对接（变更 1）', () {
    testWidgets('notesRoot 传笔记库根目录 → assets/images 下的图片能解析到', (tester) async {
      final paths = VaultPaths2.at(Directory(p.join(root.path, 'notepad')));
      await tester.runAsync(() => paths.ensureLayout());

      final hash = '1' * 64;
      final f = paths.imageFile(hash, 'png')
        ..writeAsBytesSync(<int>[
          0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
          0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
          0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
          0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
          0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
          0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
          0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
          0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
          0x42, 0x60, 0x82,
        ]);
      expect(f.existsSync(), isTrue);

      await pump(
        tester,
        '![图](${VaultPaths.imageRef(hash, 'png')})',
        notesRoot: paths.root.path,
      );
      await tester.pump();

      expect(find.text('图片缺失'), findsNothing);
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      expect(images.any((i) => i.image is FileImage), isTrue);
    });

    testWidgets('notesRoot 指向错误目录（没带上 notepad/）→ 报图片缺失', (tester) async {
      final paths = VaultPaths2.at(Directory(p.join(root.path, 'notepad')));
      await tester.runAsync(() => paths.ensureLayout());
      final hash = '2' * 64;
      paths.imageFile(hash, 'png').writeAsBytesSync(<int>[1, 2, 3]);

      await pump(
        tester,
        '![图](${VaultPaths.imageRef(hash, 'png')})',
        notesRoot: root.path, // 少了一层 notepad/
      );
      expect(find.text('图片缺失'), findsOneWidget);
    });

    testWidgets('theme/ 下的背景图不会被笔记正文引用到（目录隔离）', (tester) async {
      final paths = VaultPaths2.at(Directory(p.join(root.path, 'notepad')));
      await tester.runAsync(() => paths.ensureLayout());
      final hash = '3' * 64;
      File(p.join(paths.themeDir.path, '$hash.jpg')).writeAsBytesSync(<int>[1]);

      await pump(
        tester,
        '![背景](assets/images/$hash.jpg)',
        notesRoot: paths.root.path,
      );
      expect(find.text('图片缺失'), findsOneWidget,
          reason: '背景图不在 assets/images，正文引用它应该是缺失态');
    });

    testWidgets('导出目录里的图片同样能解析（导出产物可独立预览）', (tester) async {
      // 模拟导出目录：<export>/assets/images/<hash>.png
      final exportRoot = Directory(p.join(root.path, 'exported'))
        ..createSync(recursive: true);
      final hash = '4' * 64;
      writePng('$hash.png', dir: Directory(p.join(exportRoot.path, 'assets', 'images')));

      await pump(
        tester,
        '![图](assets/images/$hash.png)',
        notesRoot: exportRoot.path,
      );
      await tester.pump();
      expect(find.text('图片缺失'), findsNothing);
    });
  });

  group('其他边界', () {
    testWidgets('file:// 协议存在的文件能显示', (tester) async {
      final f = writePng('${'5' * 64}.png');
      await pump(tester, '![图](file://${f.path})');
      await tester.pump();
      expect(find.text('图片缺失'), findsNothing);
    });

    testWidgets('引用为空字符串不崩', (tester) async {
      await pump(tester, '![图]()');
      expect(tester.takeException(), isNull);
    });

    testWidgets('selectable=false 时不报错', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: MarkdownPreview(data: '文本', notesRoot: root.path, selectable: false),
        ),
      ));
      expect(find.byType(MarkdownBody), findsOneWidget);
    });
  });
}
