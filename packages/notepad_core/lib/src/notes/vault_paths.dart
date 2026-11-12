/// 笔记库的路径规则与安全约束。
///
/// 需求第 8 节的禁止项在这里落成可被单测钉住的函数：
/// - 禁止在 md 里写绝对路径引用图片
/// - 禁止把图片 Base64 内嵌到 md
class VaultPaths {
  VaultPaths._();

  /// 图片资源的相对目录（相对 notesRoot）。
  static const String imagesDir = 'assets/images';

  /// 笔记正文目录。
  static const String notesDir = 'notes';

  /// 主题背景目录（独立目录，不参与同步与 GC）。
  static const String themeDir = 'theme';

  /// 笔记库根目录名。
  static const String vaultDirName = 'notepad';

  /// 图片的相对引用前缀。
  static const String imageRefPrefix = '$imagesDir/';

  /// 由哈希与扩展名构造图片文件名。
  static String imageFileName(String hash, String ext) {
    final cleanExt = ext.startsWith('.') ? ext.substring(1) : ext;
    return '$hash.${cleanExt.toLowerCase()}';
  }

  /// 由哈希与扩展名构造相对引用（写入 md 的形式）。
  static String imageRef(String hash, String ext) =>
      '$imageRefPrefix${imageFileName(hash, ext)}';

  /// 笔记文件名。
  static String noteFileName(String noteId) => '$noteId.md';

  /// 校验一个图片引用是否是**合法且安全**的相对引用。
  ///
  /// 返回拒绝原因；通过则返回 null。
  static String? validateImageRef(String ref) {
    if (ref.isEmpty) return '引用为空';
    if (ref.startsWith('http://') || ref.startsWith('https://')) return null; // 外链允许
    if (ref.startsWith('/')) return '禁止绝对路径';
    if (ref.startsWith('file://')) return '禁止 file:// 协议';
    if (RegExp(r'^[A-Za-z]:[\\/]').hasMatch(ref)) return '禁止 Windows 盘符绝对路径';
    if (ref.contains('\\')) return '禁止反斜杠路径（不可移植）';
    if (ref.startsWith('data:')) return '禁止 data: URI 内嵌图片';
    if (ref.contains('base64,')) return '禁止 Base64 内嵌图片';
    if (ref.split('/').contains('..')) return '禁止路径穿越（..）';
    if (!ref.startsWith(imageRefPrefix)) {
      return '图片引用必须位于 $imageRefPrefix 下';
    }
    final name = ref.substring(imageRefPrefix.length);
    if (!RegExp(r'^[0-9a-f]{64}\.[A-Za-z0-9]+$').hasMatch(name)) {
      return '图片文件名必须是 <sha256>.<ext> 形式';
    }
    return null;
  }

  /// 检查正文里是否出现了被禁止的图片写法，返回问题列表。
  static List<String> findForbiddenImageUsage(String content) {
    final problems = <String>[];
    final re = RegExp(r'!\[[^\]]*\]\(([^)\s]+)');
    for (final m in re.allMatches(content)) {
      final reason = validateImageRef(m.group(1)!);
      if (reason != null) problems.add('${m.group(1)}: $reason');
    }
    // 单独的 data: URI / base64 内嵌
    if (RegExp(r'data:image/[a-zA-Z]+;base64,').hasMatch(content)) {
      problems.add('正文中出现 data:image/...;base64 内嵌图片');
    }
    return problems;
  }

  /// 由相对引用推回内容哈希。
  static String? hashFromRef(String ref) {
    final m = RegExp(r'([0-9a-f]{64})\.[A-Za-z0-9]+$').firstMatch(ref);
    return m?.group(1);
  }
}
