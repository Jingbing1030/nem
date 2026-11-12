/// Markdown 文档的纯逻辑：标题提取、摘要生成、图片引用抽取、插入图片。
///
/// 放在核心包里（不依赖 Flutter），这样这些规则可以被单测直接钉住。
class MarkdownDoc {
  MarkdownDoc._();

  /// 标题提取规则（需求 5.1）：
  /// 1. 取正文第一个 `# ` 开头的一级标题行；
  /// 2. 无则取首行前 30 字符；
  /// 3. 都没有则返回「未命名」。
  static String extractTitle(String content) {
    for (final line in content.split('\n')) {
      final t = line.trim();
      if (t.startsWith('#')) {
        // 支持 # / ## / ### —— 去掉所有前导 # 与空格
        final title = t.replaceFirst(RegExp(r'^#+\s*'), '').trim();
        if (title.isNotEmpty) return _clamp(title, 100);
      }
    }
    final firstLine = content
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');
    if (firstLine.isEmpty) return '未命名';
    return _clamp(firstLine, 30);
  }

  /// 摘要：正文前 100 字纯文本（去掉 Markdown 标记）。
  static String extractExcerpt(String content, {int length = 100}) {
    final plain = toPlainText(content);
    return _clamp(plain, length);
  }

  /// 把 Markdown 转成纯文本（用于摘要与列表展示）。
  static String toPlainText(String content) {
    var s = content;
    // 图片 → [图]
    s = s.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    // 链接 → 链接文字
    s = s.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'),
      (m) => m.group(1) ?? '',
    );
    // 代码块围栏
    s = s.replaceAll(RegExp(r'^```.*$', multiLine: true), ' ');
    // 行内代码标记
    s = s.replaceAll('`', '');
    // 标题、列表、引用、加粗、斜体等标记
    s = s.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
    s = s.replaceAll(RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true), '');
    s = s.replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '');
    s = s.replaceAll(RegExp(r'^\s{0,3}\d+\.\s+', multiLine: true), '');
    s = s.replaceAll(RegExp(r'(\*\*|__|\*|_|~~)'), '');
    // 水平线
    s = s.replaceAll(RegExp(r'^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$', multiLine: true), ' ');
    // 空白归一
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    return s;
  }

  /// 抽取正文引用的所有图片相对路径（用于 GC 与同步的 imageHashes）。
  ///
  /// 只认 `![...](path)` 里的 path；忽略 http/https 外链。
  static List<String> extractImagePaths(String content) {
    final out = <String>[];
    final re = RegExp(r'!\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)');
    for (final m in re.allMatches(content)) {
      final path = m.group(1)!;
      if (path.startsWith('http://') || path.startsWith('https://')) continue;
      out.add(path);
    }
    return out;
  }

  /// 抽取图片的 SHA-256 哈希（从 `assets/images/<hash>.<ext>` 路径解析）。
  static List<String> extractImageHashes(String content) {
    final out = <String>[];
    for (final p in extractImagePaths(content)) {
      final m = RegExp(r'([0-9a-f]{64})\.[A-Za-z0-9]+$').firstMatch(p);
      if (m != null) out.add(m.group(1)!);
    }
    return out;
  }

  /// 在指定光标位置插入图片 Markdown，返回新正文与新光标位置。
  static (String, int) insertImage(
    String content,
    int cursor,
    String hash,
    String ext, {
    String alt = '图片',
  }) {
    final ref = '![$alt](assets/images/$hash.$ext)';
    final safeCursor = cursor.clamp(0, content.length);
    final before = content.substring(0, safeCursor);
    final after = content.substring(safeCursor);
    // 光标前若不在行首、且不是空白，补一个换行，避免图片引用黏在文字后面
    final needsLeadingNewline =
        before.isNotEmpty && !before.endsWith('\n');
    final insertion = '${needsLeadingNewline ? '\n' : ''}$ref';
    final newContent = before + insertion + after;
    return (newContent, before.length + insertion.length);
  }

  static String _clamp(String s, int max) =>
      s.length <= max ? s : s.substring(0, max);
}
