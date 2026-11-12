import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/db/database.dart';
import 'package:lan_notepad/src/db/note_repository.dart';
import 'package:lan_notepad/src/db/paths.dart';
import 'package:notepad_core/notepad_core.dart';
import 'package:path/path.dart' as p;

/// `NoteRepository2` + `AppDatabase`（变更 1：正文入库）单元测试。
///
/// 全部用例都把库开在临时目录的文件上，避开 path_provider 的平台依赖。
void main() {
  late Directory tmp;
  late AppDatabase db;
  late NoteRepository2 repo;
  late VaultPaths2 paths;
  late DateTime now;

  const deviceA = 'dev-A';
  const deviceB = 'dev-B';
  const h1 =
      '1111111111111111111111111111111111111111111111111111111111111111';
  const h2 =
      '2222222222222222222222222222222222222222222222222222222222222222';

  AppDatabase openDb() => AppDatabase.atFile(File(p.join(tmp.path, 'notes.db')));

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('note_repo_test');
    db = openDb();
    now = DateTime.utc(2026, 11, 12, 10, 0, 0);
    paths = VaultPaths2.at(Directory(p.join(tmp.path, 'notepad')));
    repo = NoteRepository2(
      db: db,
      paths: paths,
      deviceId: deviceA,
      clock: () => now,
    );
    // 触发一次真实查询，确保 schema 已建好（drift 是惰性打开）。
    expect(await db.integrityCheck(), 'ok');
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('新建与读回：content 落库', () {
    test('新建后能读回，正文存在 content 列里', () async {
      final id = await repo.create(content: '# 标题\n\n正文内容');

      final n = await db.noteById(id);
      expect(n, isNotNull);
      expect(n!.content, '# 标题\n\n正文内容');
      expect(n.title, '标题');
      expect(n.isDeleted, isFalse);
    });

    test('新建时不再产生任何 md 文件（正文唯一真相源是 DB）', () async {
      final id = await repo.create(content: '# 标题\n正文');
      // 库文件在，笔记目录里没有 notes/ 也没有 .md
      expect(File(p.join(tmp.path, 'notes.db')).existsSync(), isTrue);
      final stray = paths.root.existsSync()
          ? paths.root
              .listSync(recursive: true)
              .where((e) => e.path.endsWith('.md'))
              .toList()
          : <FileSystemEntity>[];
      expect(stray, isEmpty, reason: '新建笔记不应写 md（正文唯一真相源是 DB）');
      expect(paths.dbFile.existsSync(), isFalse,
          reason: 'repository 不应在没调用 ensureLayout 时写任何文件');
      expect(await db.noteById(id), isNotNull);
    });

    test('create 返回的 noteId 是 UUID v4，互不相同', () async {
      final a = await repo.create();
      final b = await repo.create();
      expect(a, isNot(b));
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(a),
        isTrue,
        reason: '应是 UUID v4：$a',
      );
    });

    test('createdAt / updatedAt 是 int 毫秒且等于时钟值', () async {
      final id = await repo.create(content: 'x');
      final n = (await db.noteById(id))!;
      expect(n.createdAt, now.millisecondsSinceEpoch);
      expect(n.updatedAt, now.millisecondsSinceEpoch);
    });

    test('all() 含墓碑、visibleNotes() 不含，且按 updatedAt 倒序', () async {
      final a = await repo.create(content: 'A');
      now = now.add(const Duration(minutes: 1));
      final b = await repo.create(content: 'B');
      now = now.add(const Duration(minutes: 1));
      final c = await repo.create(content: 'C');
      await repo.softDelete(b);

      expect((await repo.visibleNotes()).map((n) => n.noteId).toList(),
          <String>[c, a]);
      expect((await repo.all()).length, 3);
    });
  });

  group('版本向量：每次本地写入都自增', () {
    test('新建 → 本机计数为 1', () async {
      final id = await repo.create(content: 'x');
      final vv = VersionVector.decode((await db.noteById(id))!.versionVector);
      expect(vv[deviceA], 1);
      expect(vv.counters.length, 1);
    });

    test('连续保存 → 计数逐次 +1，不重置', () async {
      final id = await repo.create(content: 'v1');

      final v2 = await repo.saveContent(id, 'v2');
      expect(v2[deviceA], 2);
      final v3 = await repo.saveContent(id, 'v3');
      expect(v3[deviceA], 3);

      final stored = VersionVector.decode((await db.noteById(id))!.versionVector);
      expect(stored[deviceA], 3);
      expect(stored, v3);
    });

    test('saveContent 返回值与落库的向量一致（供同步判断）', () async {
      final id = await repo.create(content: 'a');
      final returned = await repo.saveContent(id, 'b');
      expect((await db.noteById(id))!.versionVector, returned.encode());
    });

    test('软删除同样推进版本向量（否则墓碑传不出去）', () async {
      final id = await repo.create(content: 'x');
      final vv = await repo.softDelete(id);
      expect(vv[deviceA], 2);
      expect(
        VersionVector.decode((await db.noteById(id))!.versionVector),
        vv,
      );
    });

    test('未知设备 id 的计数视为 0', () async {
      final id = await repo.create(content: 'x');
      final vv = VersionVector.decode((await db.noteById(id))!.versionVector);
      expect(vv[deviceB], 0);
      expect(vv.deviceIds, <String>{deviceA});
    });
  });

  group('contentHash = SHA-256(content)', () {
    test('与 Hashing.contentHash 一致', () async {
      const content = '# 标题\n\n正文 with emoji 🙂\n';
      final id = await repo.create(content: content);
      expect((await db.noteById(id))!.contentHash, Hashing.contentHash(content));
      expect((await db.noteById(id))!.contentHash.length, 64);
    });

    test('内容变了哈希就变，内容不变哈希不变', () async {
      final id = await repo.create(content: 'same');
      final h1 = (await db.noteById(id))!.contentHash;
      await repo.saveContent(id, 'same');
      expect((await db.noteById(id))!.contentHash, h1);
      await repo.saveContent(id, 'different');
      expect((await db.noteById(id))!.contentHash, isNot(h1));
    });

    test('空正文也有确定的哈希', () async {
      final id = await repo.create();
      expect((await db.noteById(id))!.contentHash, Hashing.contentHash(''));
    });
  });

  group('imageHashes：从正文抽取并存成 JSON 数组', () {

    test('抽取 assets/images/<hash>.<ext> 形式的引用', () async {
      final md = '# 图\n\n![a](assets/images/$h1.png)\n\n![b](assets/images/$h2.jpg)';
      final id = await repo.create(content: md);

      final raw = (await db.noteById(id))!.imageHashes;
      expect(jsonDecode(raw), <String>[h1, h2]);
    });

    test('外链与非法引用不被计入', () async {
      final md = '![net](https://example.com/a.png)\n\n'
          '![wrong](assets/images/not-a-hash.png)';
      final id = await repo.create(content: md);
      expect(jsonDecode((await db.noteById(id))!.imageHashes), isEmpty);
    });

    test('没有图片时是空 JSON 数组而不是乱码', () async {
      final id = await repo.create(content: '纯文字');
      expect((await db.noteById(id))!.imageHashes, '[]');
      expect(jsonDecode((await db.noteById(id))!.imageHashes), isEmpty);
    });

    test('再次保存会随正文更新 imageHashes', () async {
      final id = await repo.create(content: '无图');
      expect(jsonDecode((await db.noteById(id))!.imageHashes), isEmpty);

      await repo.saveContent(id, '![a](assets/images/$h1.webp)');
      expect(jsonDecode((await db.noteById(id))!.imageHashes), <String>[h1]);

      await repo.saveContent(id, '图删掉了');
      expect(jsonDecode((await db.noteById(id))!.imageHashes), isEmpty);
    });

    test('toMeta 能把 JSON 还原成 List<String>', () async {
      final id = await repo.create(content: '![a](assets/images/$h1.png)');
      final meta = NoteRepository2.toMeta((await db.noteById(id))!);
      expect(meta.imageHashes, <String>[h1]);
      expect(meta.content, '![a](assets/images/$h1.png)');
      expect(meta.isDeleted, isFalse);
    });

    test('toMeta 对损坏的 JSON 兜底为空列表', () async {
      final id = await repo.create(content: 'x');
      await db.upsertNote(
        noteId: id,
        title: 't',
        content: 'x',
        excerpt: 'x',
        versionVector: '{"$deviceA":1}',
        contentHash: Hashing.contentHash('x'),
        imageHashesJson: '这不是 JSON',
        createdAt: now,
        updatedAt: now,
      );
      expect(NoteRepository2.toMeta((await db.noteById(id))!).imageHashes, isEmpty);
    });
  });

  group('标题与摘要提取规则', () {
    test('有 # 标题行 → 用 # 后的文字', () async {
      final id = await repo.create(content: '开头一段\n# 真标题\n正文');
      expect((await db.noteById(id))!.title, '真标题');
    });

    test('## / ### 多级标题同样识别', () async {
      final a = await repo.create(content: '## 二级');
      final b = await repo.create(content: '### 三级');
      expect((await db.noteById(a))!.title, '二级');
      expect((await db.noteById(b))!.title, '三级');
    });

    test('无 # → 取首行前 30 字', () async {
      final long = '一二三四五六七八九十' * 6; // 60 字
      final id = await repo.create(content: '$long\n第二行');
      final title = (await db.noteById(id))!.title;
      expect(title, long.substring(0, 30));
      expect(title.length, 30);
      expect(title.contains('第二行'), isFalse);
    });

    test('无 # 且首行短 → 就是首行', () async {
      final id = await repo.create(content: '短首行\n\n后面还有很多正文');
      expect((await db.noteById(id))!.title, '短首行');
    });

    test('首行是空行时会往下找第一段非空内容', () async {
      final id = await repo.create(content: '\n\n   \n真正的首行');
      expect((await db.noteById(id))!.title, '真正的首行');
    });

    test('完全空 → 「未命名」', () async {
      final id = await repo.create(content: '');
      expect((await db.noteById(id))!.title, '未命名');
    });

    test('只有空白的正文 → 「未命名」', () async {
      final id = await repo.create(content: '\n\n   \n');
      expect((await db.noteById(id))!.title, '未命名');
    });

    test('显式传 title 时优先用传进来的', () async {
      final id = await repo.create(content: '# 正文标题', title: '手动标题');
      expect((await db.noteById(id))!.title, '手动标题');
    });

    test('saveContent 会重算标题（改了 # 标题就跟着变）', () async {
      final id = await repo.create(content: '# 旧标题');
      await repo.saveContent(id, '# 新标题\n正文');
      expect((await db.noteById(id))!.title, '新标题');
    });

    test('摘要取正文前 100 字纯文本，且去掉 Markdown 标记', () async {
      final id = await repo.create(
        content: '# 标题\n\n![图](assets/images/$h1.png)正文**加粗**内容',
      );
      final excerpt = (await db.noteById(id))!.excerpt;
      expect(excerpt.contains('#'), isFalse);
      expect(excerpt.contains('**'), isFalse);
      expect(excerpt.contains('assets/images'), isFalse);
      expect(excerpt.contains('正文'), isTrue);
      expect(excerpt.contains('加粗'), isTrue);
    });

    test('超长正文的摘要被截到 100 字', () async {
      final id = await repo.create(content: '啊' * 500);
      expect((await db.noteById(id))!.excerpt.length, 100);
    });
  });

  group('软删除（墓碑）', () {
    test('isDeleted=true、updatedAt 更新、版本向量推进', () async {
      final id = await repo.create(content: 'x');
      final before = (await db.noteById(id))!;

      now = now.add(const Duration(minutes: 5));
      final vv = await repo.softDelete(id);

      final after = (await db.noteById(id))!;
      expect(after.isDeleted, isTrue);
      expect(after.updatedAt, now.millisecondsSinceEpoch);
      expect(after.updatedAt, greaterThan(before.updatedAt));
      expect(vv[deviceA], 2);
      expect(VersionVector.decode(after.versionVector)[deviceA], 2);
    });

    test('墓碑仍在库里（供同步传播），只是不出现在列表', () async {
      final id = await repo.create(content: 'x');
      await repo.softDelete(id);
      expect(await db.noteById(id), isNotNull);
      expect((await repo.visibleNotes()), isEmpty);
      expect((await repo.all()).length, 1);
    });

    test('软删除会清空正文（省空间）但保留标题与 noteId', () async {
      final id = await repo.create(content: '# 标题\n很长的正文');
      await repo.softDelete(id);
      final n = (await db.noteById(id))!;
      expect(n.content, '');
      expect(n.title, '标题');
      expect(n.noteId, id);
    });

    test('对端墓碑：applyRemoteDelete 合并版本向量', () async {
      final id = await repo.create(content: 'x'); // {A:1}
      await repo.applyRemoteDelete(id, VersionVector(<String, int>{deviceB: 4}));

      final n = (await db.noteById(id))!;
      expect(n.isDeleted, isTrue);
      expect(VersionVector.decode(n.versionVector).counters,
          <String, int>{deviceA: 1, deviceB: 4});
    });

    test('applyRemoteDelete 对不存在的笔记是安全的空操作', () async {
      await repo.applyRemoteDelete('不存在', VersionVector(<String, int>{deviceB: 1}));
      expect(await repo.all(includeDeleted: false), isEmpty);
    });
  });

  group('writeFromPeer：合并版本向量（逐项最大值）', () {
    test('接收远端内容并逐项取最大值', () async {
      final id = await repo.create(content: 'local'); // {A:1}
      await repo.saveContent(id, 'local2'); // {A:2}

      await repo.writeFromPeer(
        noteId: id,
        content: 'remote',
        remoteVersionVector: VersionVector(<String, int>{deviceA: 1, deviceB: 5}),
        contentHash: Hashing.contentHash('remote'),
        imageHashes: const <String>[],
      );

      final n = (await db.noteById(id))!;
      expect(VersionVector.decode(n.versionVector).counters,
          <String, int>{deviceA: 2, deviceB: 5},
          reason: 'A 取 max(2,1)=2，B 取 5');
      expect(n.content, 'remote');
    });

    test('远端向量更旧时不回退本地计数（不发生 LWW 覆盖）', () async {
      final id = await repo.create(content: 'x');
      await repo.saveContent(id, 'y');
      await repo.saveContent(id, 'z'); // {A:3}

      await repo.writeFromPeer(
        noteId: id,
        content: '旧的远端',
        remoteVersionVector: VersionVector(<String, int>{deviceA: 1}),
        contentHash: Hashing.contentHash('旧的远端'),
        imageHashes: const <String>[],
      );

      expect(
        VersionVector.decode((await db.noteById(id))!.versionVector).counters,
        <String, int>{deviceA: 3},
      );
    });

    test('对端新笔记（本地没有）直接落库', () async {
      await repo.writeFromPeer(
        noteId: 'peer-1',
        content: '# 对端的笔记\n内容',
        remoteVersionVector: VersionVector(<String, int>{deviceB: 1}),
        contentHash: Hashing.contentHash('# 对端的笔记\n内容'),
        imageHashes: const <String>[],
      );
      final n = (await db.noteById('peer-1'))!;
      expect(n.title, '对端的笔记');
      expect(n.content, '# 对端的笔记\n内容');
      expect(n.isDeleted, isFalse);
    });

    test('传进来的 imageHashes 原样落库为 JSON', () async {
      const hx =
          '3333333333333333333333333333333333333333333333333333333333333333';
      await repo.writeFromPeer(
        noteId: 'peer-2',
        content: '无图正文',
        remoteVersionVector: VersionVector(<String, int>{deviceB: 2}),
        contentHash: Hashing.contentHash('无图正文'),
        imageHashes: const <String>[hx],
      );
      expect(jsonDecode((await db.noteById('peer-2'))!.imageHashes),
          <String>[hx]);
    });

    test('contentHash 为空时按正文重算', () async {
      await repo.writeFromPeer(
        noteId: 'peer-3',
        content: 'abc',
        remoteVersionVector: VersionVector(<String, int>{deviceB: 1}),
        contentHash: '',
        imageHashes: const <String>[],
      );
      expect((await db.noteById('peer-3'))!.contentHash, Hashing.contentHash('abc'));
    });

    test('写对端内容会复活墓碑（对端认为它没被删）', () async {
      final id = await repo.create(content: 'x');
      await repo.softDelete(id);
      await repo.writeFromPeer(
        noteId: id,
        content: '复活',
        remoteVersionVector: VersionVector(<String, int>{deviceB: 9}),
        contentHash: Hashing.contentHash('复活'),
        imageHashes: const <String>[],
      );
      final n = (await db.noteById(id))!;
      expect(n.isDeleted, isFalse);
      expect(n.content, '复活');
    });

    test('createdAt 在既有笔记上保持不变', () async {
      final id = await repo.create(content: 'x');
      final created = (await db.noteById(id))!.createdAt;
      now = now.add(const Duration(hours: 3));
      await repo.writeFromPeer(
        noteId: id,
        content: 'y',
        remoteVersionVector: VersionVector(<String, int>{deviceB: 1}),
        contentHash: Hashing.contentHash('y'),
        imageHashes: const <String>[],
      );
      expect((await db.noteById(id))!.createdAt, created);
    });
  });

  group('冲突副本', () {
    test('生成新 noteId（与原件不同）且标题带「（冲突副本）」后缀', () async {
      final id = await repo.create(content: '# 我的笔记\n内容');
      final loser = NoteRepository2.toMeta((await db.noteById(id))!);

      final copyId = await repo.saveConflictCopy(loser);

      expect(copyId, isNot(id));
      final copy = (await db.noteById(copyId))!;
      expect(copy.title, '我的笔记$conflictTitleSuffix');
      expect(copy.content, '# 我的笔记\n内容');
      expect((await db.noteById(id))!.title, '我的笔记',
          reason: '原件标题不应被改写');
    });

    test('副本与原件的 noteId 都在库里，两份都保留', () async {
      final id = await repo.create(content: 'x');
      final copyId = await repo.saveConflictCopy(
        NoteRepository2.toMeta((await db.noteById(id))!),
      );
      expect((await repo.all()).map((n) => n.noteId).toSet(),
          <String>{id, copyId});
    });

    test('空标题的副本用「未命名」打底', () async {
      final id = await repo.create(content: '');
      final copyId = await repo.saveConflictCopy(
        NoteRepository2.toMeta((await db.noteById(id))!),
      );
      expect((await db.noteById(copyId))!.title, '未命名$conflictTitleSuffix');
    });

    test('副本保留丢失方的版本向量（内容确实是那一份）', () async {
      final id = await repo.create(content: '# T\n内容');
      final loser = NoteRepository2.toMeta((await db.noteById(id))!);
      final copyId = await repo.saveConflictCopy(loser);
      final copy = (await db.noteById(copyId))!;
      expect(VersionVector.decode(copy.versionVector), loser.versionVector);
      expect(copy.contentHash, Hashing.contentHash('# T\n内容'));
    });

    test('副本正文里若有图片，imageHashes 一并带过去', () async {
      const hx =
          '4444444444444444444444444444444444444444444444444444444444444444';
      final id = await repo.create(content: '![a](assets/images/$hx.png)');
      final copyId = await repo.saveConflictCopy(
        NoteRepository2.toMeta((await db.noteById(id))!),
      );
      expect(jsonDecode((await db.noteById(copyId))!.imageHashes), <String>[hx]);
    });

    test('同一毫秒内两次 saveConflictCopy 不会撞 id（防回归）', () async {
      final id = await repo.create(content: 'x');
      final meta = NoteRepository2.toMeta((await db.noteById(id))!);

      // 固定时钟：让两次调用的毫秒完全相同，专门逼出「同毫秒」这个条件。
      // 早期实现的 id 只由 (noteId, 当前毫秒) 决定，此时会拿到同一个 id，
      // 第二次 upsert 静默覆盖第一次 → 一份冲突副本丢失。
      // 修复方式是给 id 附加安全随机后缀。
      final a = await repo.saveConflictCopy(meta);
      final b = await repo.saveConflictCopy(meta);

      expect(a, isNot(b), reason: '同毫秒内的两次副本必须拿到不同 id（否则会互相覆盖）');
      expect((await db.allNotes()).length, 3,
          reason: '原件 1 + 两次副本 2 = 3 行；只有 2 行说明有一份副本被覆盖了');

      // 两份副本的内容都必须真的在库里可读
      final copyA = await db.noteById(a);
      final copyB = await db.noteById(b);
      expect(copyA, isNotNull);
      expect(copyB, isNotNull);
      expect(copyA!.noteId, isNot(copyB!.noteId));
    });

    test('副本 id 保留可追溯前缀（便于排查同步问题）', () async {
      final id = await repo.create(content: 'x');
      final meta = NoteRepository2.toMeta((await db.noteById(id))!);
      final copyId = await repo.saveConflictCopy(meta);
      expect(copyId.startsWith('${id}-c'), isTrue,
          reason: '副本 id 应以 <原id>-c 开头，便于看出它是谁的副本');
    });
  });

  group('重启后数据保留（关库再用同一文件重开）', () {
    test('笔记、正文、版本向量、imageHashes 全部还在', () async {
      const hx =
          '5555555555555555555555555555555555555555555555555555555555555555';
      final id = await repo.create(content: '![a](assets/images/$hx.png)\n正文');
      await repo.saveContent(id, '# 标题\n![a](assets/images/$hx.png)\n重启前写入');

      await db.close();

      db = openDb();
      repo = NoteRepository2(
        db: db,
        paths: paths,
        deviceId: deviceA,
        clock: () => now,
      );

      final n = await db.noteById(id);
      expect(n, isNotNull);
      expect(n!.title, '标题');
      expect(n.content, contains('重启前写入'));
      expect(n.contentHash, Hashing.contentHash(n.content));
      expect(jsonDecode(n.imageHashes), <String>[hx]);
      expect(VersionVector.decode(n.versionVector).counters,
          <String, int>{deviceA: 2});
    });

    test('墓碑也保留（重启不会「复活」已删除的笔记）', () async {
      final id = await repo.create(content: 'x');
      await repo.softDelete(id);
      await db.close();

      db = openDb();
      final n = await db.noteById(id);
      expect(n, isNotNull);
      expect(n!.isDeleted, isTrue);
      expect(await db.allNotes(includeDeleted: false), isEmpty);
    });

    test('重启后继续保存，版本向量接着涨而不是从 1 重新开始', () async {
      final id = await repo.create(content: 'a');
      await repo.saveContent(id, 'b'); // {A:2}
      await db.close();

      db = openDb();
      repo = NoteRepository2(
        db: db,
        paths: paths,
        deviceId: deviceA,
        clock: () => now,
      );
      final vv = await repo.saveContent(id, 'c');
      expect(vv[deviceA], 3);
    });
  });

  group('事务性（写入中断不留半写状态）', () {
    test('外层事务抛异常 → 笔记与搜索索引都不留痕', () async {
      await expectLater(
        db.transaction(() async {
          await db.upsertNote(
            noteId: 'tx-1',
            title: '标题',
            content: '正文',
            excerpt: '正文',
            versionVector: '{"$deviceA":1}',
            contentHash: Hashing.contentHash('正文'),
            imageHashesJson: '[]',
            createdAt: now,
            updatedAt: now,
          );
          throw StateError('模拟写入过程中断电/异常');
        }),
        throwsA(isA<StateError>()),
      );

      expect(await db.noteById('tx-1'), isNull, reason: 'notes 表不应有半写记录');
      final idx = await db
          .customSelect("SELECT COUNT(*) AS n FROM search_index WHERE note_id = 'tx-1'")
          .getSingle();
      expect(idx.data['n'], 0, reason: 'search_index 也不应有残留');
    });

    test('事务回滚不影响事务之外的既有数据', () async {
      final ok = await repo.create(content: '# 已存在');
      await expectLater(
        db.transaction(() async {
          await repo.saveContent(ok, '# 被改坏的标题');
          throw StateError('boom');
        }),
        throwsA(isA<StateError>()),
      );
      expect((await db.noteById(ok))!.title, '已存在');
    });

    test('upsertNote 成功时笔记与索引同批写入（要么都有要么都没有）', () async {
      final id = await repo.create(content: '# 有索引');
      final idx = await db
          .customSelect("SELECT title FROM search_index WHERE note_id = '$id'")
          .getSingle();
      expect(idx.data['title'], '有索引');
    });

    test('软删除同一事务清掉搜索索引（墓碑不该被搜到）', () async {
      final id = await repo.create(content: '# 会被删');
      await repo.softDelete(id);
      final idx = await db
          .customSelect("SELECT COUNT(*) AS n FROM search_index WHERE note_id = '$id'")
          .getSingle();
      expect(idx.data['n'], 0);
    });
  });

  group('底层 upsertNote 的行为（repository 之外的直接调用）', () {
    test('同 noteId 二次 upsert 是更新而不是重复插入', () async {
      await repo.create(content: 'a');
      final id = (await repo.all()).single.noteId;
      await repo.saveContent(id, 'b');
      expect((await db.allNotes(includeDeleted: false)).length, 1);
    });

    test('重复 upsert 后 search_index 里也只有一行（先删后插）', () async {
      final id = await repo.create(content: '# A');
      await repo.saveContent(id, '# B');
      await repo.saveContent(id, '# C');
      final idx = await db
          .customSelect("SELECT COUNT(*) AS n FROM search_index WHERE note_id = '$id'")
          .getSingle();
      expect(idx.data['n'], 1);
      final row = await db
          .customSelect("SELECT title FROM search_index WHERE note_id = '$id'")
          .getSingle();
      expect(row.data['title'], 'C');
    });

    test('noteById 对不存在的 id 返回 null', () async {
      expect(await db.noteById('no-such-id'), isNull);
    });
  });
}
