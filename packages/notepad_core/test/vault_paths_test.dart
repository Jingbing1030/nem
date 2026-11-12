import 'package:notepad_core/notepad_core.dart';
import 'package:test/test.dart';

void main() {
  const h = 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2';

  group('图片文件名与相对引用', () {
    test('文件名 = <hash>.<ext>', () {
      expect(VaultPaths.imageFileName(h, 'png'), '$h.png');
    });

    test('扩展名带点也能处理，并统一小写', () {
      expect(VaultPaths.imageFileName(h, '.JPG'), '$h.jpg');
    });

    test('相对引用位于 assets/images/ 下', () {
      expect(VaultPaths.imageRef(h, 'webp'), 'assets/images/$h.webp');
    });
  });

  group('合法性校验：拒绝项（需求第 8 节）', () {
    test('拒绝绝对路径', () {
      expect(VaultPaths.validateImageRef('/sdcard/img/x.png'), contains('绝对路径'));
    });

    test('拒绝 file:// 协议', () {
      expect(VaultPaths.validateImageRef('file:///tmp/x.png'), contains('file://'));
    });

    test('拒绝 Windows 盘符路径', () {
      expect(VaultPaths.validateImageRef(r'C:\Users\x.png'), isNotNull);
    });

    test('拒绝反斜杠路径', () {
      expect(VaultPaths.validateImageRef(r'assets\images\x.png'), contains('反斜杠'));
    });

    test('拒绝 data: URI 内嵌', () {
      expect(VaultPaths.validateImageRef('data:image/png;base64,AAAA'), contains('data:'));
    });

    test('拒绝含 base64 的写法', () {
      expect(
        VaultPaths.validateImageRef('assets/images/x.base64,AAAA'),
        isNotNull,
      );
    });

    test('拒绝路径穿越', () {
      expect(
        VaultPaths.validateImageRef('assets/images/../../etc/passwd'),
        contains('路径穿越'),
      );
    });

    test('拒绝不在 assets/images 下的相对路径', () {
      expect(VaultPaths.validateImageRef('theme/bg.jpg'), contains('assets/images'));
      expect(VaultPaths.validateImageRef('other/$h.png'), contains('assets/images'));
    });

    test('拒绝非 <hash>.<ext> 形式的文件名', () {
      expect(VaultPaths.validateImageRef('assets/images/my-photo.png'), isNotNull);
      expect(VaultPaths.validateImageRef('assets/images/$h'), isNotNull);
    });

    test('空引用被拒', () {
      expect(VaultPaths.validateImageRef(''), contains('为空'));
    });
  });

  group('合法性校验：通过项', () {
    test('标准内容寻址引用通过', () {
      expect(VaultPaths.validateImageRef('assets/images/$h.png'), isNull);
      expect(VaultPaths.validateImageRef('assets/images/$h.jpeg'), isNull);
      expect(VaultPaths.validateImageRef('assets/images/$h.webp'), isNull);
    });

    test('外链（http/https）允许 —— 不属于本地图片资源', () {
      expect(VaultPaths.validateImageRef('https://example.com/a.png'), isNull);
      expect(VaultPaths.validateImageRef('http://example.com/a.png'), isNull);
    });
  });

  group('正文扫描：找出被禁止的写法', () {
    test('合法正文无问题', () {
      final md = '# 标题\n![图](assets/images/$h.png)';
      expect(VaultPaths.findForbiddenImageUsage(md), isEmpty);
    });

    test('抓到绝对路径引用', () {
      final md = '![图](/sdcard/DCIM/a.png)';
      final problems = VaultPaths.findForbiddenImageUsage(md);
      expect(problems.length, 1);
      expect(problems.first, contains('绝对路径'));
    });

    test('抓到 Base64 内嵌', () {
      final md = '![图](data:image/png;base64,iVBORw0KGgo=)';
      expect(VaultPaths.findForbiddenImageUsage(md), isNotEmpty);
    });

    test('抓到裸露的 base64 图片数据', () {
      final md = '正文 data:image/jpeg;base64,AAAA 结束';
      expect(VaultPaths.findForbiddenImageUsage(md), isNotEmpty);
    });
  });

  group('从引用反解哈希', () {
    test('正常反解', () {
      expect(VaultPaths.hashFromRef('assets/images/$h.png'), h);
    });

    test('非法引用返回 null', () {
      expect(VaultPaths.hashFromRef('assets/images/whatever.png'), isNull);
    });
  });

  group('目录常量（防止背景图混入图片资源）', () {
    test('主题背景目录独立于图片资源目录', () {
      expect(VaultPaths.themeDir, 'theme');
      expect(VaultPaths.imagesDir, 'assets/images');
      expect(VaultPaths.themeDir == VaultPaths.imagesDir, isFalse);
      expect(
        VaultPaths.themeDir.startsWith(VaultPaths.imagesDir),
        isFalse,
        reason: '背景图不得位于 assets/images 之下，否则会被 GC 与同步波及',
      );
    });
  });
}
