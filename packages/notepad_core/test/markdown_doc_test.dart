import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

void main() {
  group('标题提取（需求 5.1 三条规则）', () {
    test('取第一个 # 标题行', () {
      expect(MarkdownDoc.extractTitle('# 我的笔记\n\n正文'), '我的笔记');
    });

    test('多级标题也能取', () {
      expect(MarkdownDoc.extractTitle('## 二级标题\n正文'), '二级标题');
      expect(MarkdownDoc.extractTitle('### 三级'), '三级');
    });

    test('跳过前面的空行与正文，找第一个标题', () {
      expect(
        MarkdownDoc.extractTitle('\n\n随便一句\n\n# 真正的标题\n'),
        '真正的标题',
      );
    });

    test('无标题行 → 取首行前 30 字符', () {
      expect(MarkdownDoc.extractTitle('这是第一行正文\n第二行'), '这是第一行正文');
    });

    test('无标题且首行超 30 字 → 截断到 30', () {
      final long = 'a' * 100;
      expect(MarkdownDoc.extractTitle(long).length, 30);
    });

    test('空内容 → 未命名', () {
      expect(MarkdownDoc.extractTitle(''), '未命名');
      expect(MarkdownDoc.extractTitle('\n\n   \n'), '未命名');
    });

    test('只有 # 没有文字 → 回落到首行规则', () {
      expect(MarkdownDoc.extractTitle('#\n\n正文第一行'), '#');
    });
  });

  group('摘要生成（前 100 字纯文本）', () {
    test('去掉 Markdown 标记', () {
      final md = '# 标题\n\n**加粗** 和 *斜体* 与 `代码`';
      final ex = MarkdownDoc.extractExcerpt(md);
      expect(ex.contains('#'), isFalse);
      expect(ex.contains('*'), isFalse);
      expect(ex.contains('`'), isFalse);
      expect(ex.contains('加粗'), isTrue);
    });

    test('图片替换为空白，不把路径写进摘要', () {
      final md = '看图 ![图](assets/images/${'a' * 64}.png) 结束';
      final ex = MarkdownDoc.extractExcerpt(md);
      expect(ex.contains('assets/images'), isFalse);
      expect(ex.contains('看图'), isTrue);
      expect(ex.contains('结束'), isTrue);
    });

    test('链接保留文字、丢掉 URL', () {
      final ex = MarkdownDoc.extractExcerpt('[点我](https://example.com/x)');
      expect(ex, '点我');
    });

    test('长度上限 100', () {
      expect(MarkdownDoc.extractExcerpt('字' * 500).length, 100);
    });

    test('列表符号被去掉', () {
      final ex = MarkdownDoc.extractExcerpt('- 第一项\n- 第二项\n1. 第三项');
      expect(ex.contains('-'), isFalse);
      expect(ex.contains('第一项'), isTrue);
      expect(ex.contains('第三项'), isTrue);
    });

    test('代码块围栏被去掉', () {
      final ex = MarkdownDoc.extractExcerpt('说明\n```dart\nvoid main(){}\n```');
      expect(ex.contains('```'), isFalse);
      expect(ex.contains('说明'), isTrue);
    });
  });

  group('图片引用抽取', () {
    test('抽取相对路径', () {
      final md = '![a](assets/images/${'1' * 64}.png)\n![b](assets/images/${'2' * 64}.jpg)';
      final paths = MarkdownDoc.extractImagePaths(md);
      expect(paths.length, 2);
      expect(paths.first, 'assets/images/${'1' * 64}.png');
    });

    test('忽略 http/https 外链', () {
      final md = '![x](https://example.com/a.png)';
      expect(MarkdownDoc.extractImagePaths(md), isEmpty);
    });

    test('带 title 的引用也能抽到路径', () {
      final md = '![a](assets/images/${'3' * 64}.png "标题")';
      expect(
        MarkdownDoc.extractImagePaths(md).single,
        'assets/images/${'3' * 64}.png',
      );
    });

    test('抽出哈希（用于 imageHashes 与 GC）', () {
      final md = '![a](assets/images/${'4' * 64}.webp)';
      expect(MarkdownDoc.extractImageHashes(md), ['4' * 64]);
    });

    test('同一图片被引用两次只算一个哈希的去重由调用方 Set 完成', () {
      final h = '5' * 64;
      final md = '![a](assets/images/$h.png) ![b](assets/images/$h.png)';
      expect(MarkdownDoc.extractImageHashes(md).toSet().length, 1);
    });
  });

  group('插入图片到光标处', () {
    test('插入到空文档', () {
      final (content, cursor) = MarkdownDoc.insertImage('', 0, 'a' * 64, 'png');
      expect(content, '![图片](assets/images/${'a' * 64}.png)');
      expect(cursor, content.length);
    });

    test('插入到行中间时前面补换行，避免黏在文字后', () {
      // 光标落在 '前面' 与 '文字' 之间
      final (content, _) = MarkdownDoc.insertImage('前面文字', 2, 'b' * 64, 'jpg');
      expect(content, '前面\n![图片](assets/images/${'b' * 64}.jpg)文字');
    });

    test('插入到行首不补多余换行', () {
      final (content, _) = MarkdownDoc.insertImage('文字', 0, 'c' * 64, 'png');
      expect(content.startsWith('![图片]'), isTrue);
    });

    test('光标在换行后不补换行', () {
      final (content, _) = MarkdownDoc.insertImage('行\n', 2, 'd' * 64, 'png');
      expect(content, '行\n![图片](assets/images/${'d' * 64}.png)');
    });

    test('光标越界被夹紧', () {
      final (content, cursor) =
          MarkdownDoc.insertImage('abc', 999, 'e' * 64, 'png');
      expect(content.startsWith('abc'), isTrue);
      expect(cursor, content.length);
    });

    test('自定义 alt 文本', () {
      final (content, _) =
          MarkdownDoc.insertImage('', 0, 'f' * 64, 'png', alt: '截图');
      expect(content.contains('[截图]'), isTrue);
    });

    test('生成的位置可被自身解析回来（往返一致）', () {
      final (content, _) = MarkdownDoc.insertImage('', 0, '9' * 64, 'png');
      expect(MarkdownDoc.extractImageHashes(content), ['9' * 64]);
    });
  });
}
