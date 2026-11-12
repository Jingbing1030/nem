import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/db/database.dart';
import 'package:lan_notepad/src/search/search_service.dart';
import 'package:notepad_core/notepad_core.dart';
import 'package:path/path.dart' as p;

/// `LikeSearchService`（变更 7 阶段 1：SQL LIKE）单元测试。
void main() {
  late Directory tmp;
  late AppDatabase db;
  late LikeSearchService svc;
  final t0 = DateTime.utc(2026, 11, 12, 10, 0, 0);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('search_test');
    db = AppDatabase.atFile(File(p.join(tmp.path, 'notes.db')));
    svc = LikeSearchService(db);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> put(
    String noteId,
    String title,
    String content, {
    bool isDeleted = false,
    int order = 0,
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
        updatedAt: t0.add(Duration(minutes: order)),
        isDeleted: isDeleted,
      );

  List<String> ids(List<Note> l) => l.map((n) => n.noteId).toList();

  group('基本检索', () {
    test('能按标题命中', () async {
      await put('n1', '会议记录', '随便写点什么');
      await put('n2', '购物清单', '牛奶 鸡蛋');
      expect(ids(await svc.search('会议')), <String>['n1']);
    });

    test('能按正文命中', () async {
      await put('n1', '标题一', '今天讨论了季度目标');
      await put('n2', '标题二', '无关内容');
      expect(ids(await svc.search('季度目标')), <String>['n1']);
    });

    test('标题与正文都不匹配 → 空结果', () async {
      await put('n1', '标题', '正文');
      expect(await svc.search('完全不存在的词'), isEmpty);
    });

    test('大小写不敏感（ASCII，SQLite LIKE 默认行为）', () async {
      await put('n1', 'Hello World', 'ABC def');
      expect(ids(await svc.search('hello')), <String>['n1']);
      expect(ids(await svc.search('HELLO')), <String>['n1']);
      expect(ids(await svc.search('abc')), <String>['n1']);
    });

    test('中文子串命中', () async {
      await put('n1', '项目计划', '第一阶段交付');
      expect(ids(await svc.search('计划')), <String>['n1']);
      expect(ids(await svc.search('第一阶段')), <String>['n1']);
    });

    test('命中多篇时都返回', () async {
      await put('a', '苹果笔记', 'x', order: 1);
      await put('b', '苹果派做法', 'y', order: 2);
      await put('c', '无关', 'z', order: 3);
      expect(ids(await svc.search('苹果')).toSet(), <String>{'a', 'b'});
    });
  });

  group('排序：标题命中优先，其次 updatedAt 倒序', () {
    test('标题命中排在正文命中之前（即使正文命中更新）', () async {
      await put('body-hit', '无关标题', '包含关键词 量子', order: 10); // 更新
      await put('title-hit', '量子笔记', '其他内容', order: 1); // 更旧

      final r = await svc.search('量子');
      expect(ids(r), <String>['title-hit', 'body-hit']);
    });

    test('同为标题命中时按 updatedAt 倒序', () async {
      await put('old', '关键词A', 'x', order: 1);
      await put('mid', '关键词B', 'x', order: 5);
      await put('new', '关键词C', 'x', order: 9);
      expect(ids(await svc.search('关键词')), <String>['new', 'mid', 'old']);
    });

    test('同为正文命中时按 updatedAt 倒序', () async {
      await put('old', 'T1', '都有关键词', order: 1);
      await put('mid', 'T2', '都有关键词', order: 5);
      await put('new', 'T3', '都有关键词', order: 9);
      expect(ids(await svc.search('都有关键词')), <String>['new', 'mid', 'old']);
    });

    test('标题同时命中正文的笔记归入「标题命中」组', () async {
      await put('both-old', '关键词在这里', '关键词也在正文', order: 1);
      await put('title-new', '标题带关键词', '无关', order: 9);
      await put('body-newest', '无关', '关键词只在正文', order: 99);

      expect(ids(await svc.search('关键词')),
          <String>['title-new', 'both-old', 'body-newest']);
    });

    test('返回顺序稳定（多次查询结果一致）', () async {
      await put('a', '排序词 1', 'x', order: 1);
      await put('b', '排序词 2', 'x', order: 2);
      final first = ids(await svc.search('排序词'));
      final second = ids(await svc.search('排序词'));
      expect(first, second);
    });
  });

  group('墓碑排除', () {
    test('已删除的笔记搜不到（即使正文匹配）', () async {
      await put('live', '活着的关键词', 'x', order: 1);
      await put('dead', '死掉的关键词', 'x', isDeleted: true, order: 2);

      expect(ids(await svc.search('关键词')), <String>['live']);
    });

    test('只有墓碑匹配时返回空', () async {
      await put('dead', '墓碑', '独有关键词', isDeleted: true);
      expect(await svc.search('独有关键词'), isEmpty);
    });

    test('软删除后立刻搜不到（索引同步清理）', () async {
      await put('n1', '标题', '关键词正文');
      expect(ids(await svc.search('关键词')), <String>['n1']);

      await db.softDelete(
        'n1',
        updatedAt: t0.add(const Duration(minutes: 5)),
        versionVector: '{"dev-A":2}',
      );

      expect(await svc.search('关键词'), isEmpty);
      expect(await svc.search('标题'), isEmpty);
    });

    test('恢复（upsert isDeleted=false）后又能搜到', () async {
      await put('n1', '标题', '关键词', isDeleted: true);
      expect(await svc.search('关键词'), isEmpty);
      await put('n1', '标题', '关键词', isDeleted: false, order: 3);
      expect(ids(await svc.search('关键词')), <String>['n1']);
    });
  });

  group('LIKE 通配符转义（安全）', () {
    test('用户输入 % 不会匹配一切', () async {
      await put('n1', '没有被百分号命中的标题', '正文也无关');

      expect(await svc.search('%'), isEmpty,
          reason: '未转义时 % 会匹配所有笔记');
      expect(await svc.search('%%'), isEmpty);
    });

    test('正文里真的有 % 时用 % 能搜到', () async {
      await put('n1', '折扣', '打 50% 折');
      await put('n2', '无关', '没有符号');
      expect(ids(await svc.search('%')), <String>['n1']);
    });

    test('用户输入 _ 不会匹配任意单字符', () async {
      await put('n1', 'abc', 'x');
      await put('n2', 'a_c', 'y');
      // 未转义时 '_' 会匹配 'abc'；转义后只匹配字面下划线
      expect(ids(await svc.search('a_c')), <String>['n2']);
      expect(ids(await svc.search('_')), <String>['n2']);
    });

    test('反斜杠本身也能被正确转义与检索', () async {
      await put('n1', '路径', r'C:\Users\test');
      expect(ids(await svc.search(r'\Users')), <String>['n1']);
    });

    test('escapeLike 静态方法与实现一致', () {
      expect(LikeSearchService.escapeLike('%'), r'\%');
      expect(LikeSearchService.escapeLike('_'), r'\_');
      expect(LikeSearchService.escapeLike(r'\'), r'\\');
      expect(LikeSearchService.escapeLike('100%_ok'), r'100\%\_ok');
      expect(LikeSearchService.escapeLike('普通文字'), '普通文字');
    });

    test('转义后的通配符仍能匹配字面量组合', () async {
      await put('n1', '进度 50%_done', 'x');
      await put('n2', '进度 50 done', 'y');
      expect(ids(await svc.search('50%_done')), <String>['n1']);
    });
  });

  group('空查询与 limit', () {
    test('空串返回空列表', () async {
      await put('n1', '标题', '正文');
      expect(await svc.search(''), isEmpty);
    });

    test('纯空白查询返回空列表', () async {
      await put('n1', '标题', '正文');
      expect(await svc.search('   \t\n  '), isEmpty);
    });

    test('查询两端空白被裁掉（不当作字面量）', () async {
      await put('n1', '关键词', 'x');
      expect(ids(await svc.search('  关键词  ')), <String>['n1']);
    });

    test('limit 生效', () async {
      for (var i = 0; i < 10; i++) {
        await put('n$i', '共享关键词 $i', 'x', order: i);
      }
      expect((await svc.search('共享关键词', limit: 3)).length, 3);
      expect((await svc.search('共享关键词', limit: 100)).length, 10);
    });

    test('limit 截断保留的是「标题命中优先」的那一批', () async {
      await put('title-hit', '关键词标题', 'x', order: 1);
      for (var i = 0; i < 5; i++) {
        await put('body-$i', 'T$i', '含关键词的正文', order: 10 + i);
      }
      final r = await svc.search('关键词', limit: 2);
      expect(ids(r).first, 'title-hit');
    });

    test('空库搜索安全返回空', () async {
      expect(await svc.search('任意'), isEmpty);
    });
  });

  group('索引与重建', () {
    test('rebuild 后仍能搜到（LIKE 实现无需索引，但接口要可用）', () async {
      await put('n1', '标题关键词', '正文');
      await svc.rebuild();
      expect(ids(await svc.search('标题关键词')), <String>['n1']);
    });

    test('SearchService 抽象可被 LikeSearchService 实现', () async {
      final SearchService s = LikeSearchService(db);
      await put('n1', '抽象接口', 'x');
      expect(ids(await s.search('抽象')), <String>['n1']);
    });

    test('搜索结果显示的是库里的最新正文（不是旧快照）', () async {
      await put('n1', '标题', '旧正文 关键词');
      await put('n1', '标题', '新正文 关键词', order: 5);
      final r = await svc.search('关键词');
      expect(r.single.content, contains('新正文'));
    });

    test('FTS 切换阈值常量符合文档（1000 万字符）', () {
      expect(LikeSearchService.ftsSwitchCharThreshold, 10000000);
    });

    test('shouldUseFts 在词量很小的时候返回 false', () async {
      await put('n1', '短', '短正文');
      expect(await FtsSearchService.shouldUseFts(db), isFalse);
    });
  });
}
