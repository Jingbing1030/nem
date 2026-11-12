/// GitHub Release 查询结果。
///
/// **只依赖 `dart:core`**，便于在单测里构造假数据、不需要网络。
class ReleaseInfo {
  const ReleaseInfo({
    required this.tagName,
    required this.htmlUrl,
    this.name = '',
    this.body = '',
    this.publishedAt,
    this.apkUrl,
  });

  /// Release tag，如 `v0.3.0`。
  final String tagName;

  /// Release 页面地址（「去下载」按钮的跳转目标）。
  final String htmlUrl;

  /// Release 标题（可能为空，此时用 tagName 展示）。
  final String name;

  /// 更新说明（Release body，Markdown 原文）。
  final String body;

  /// 发布时间（解析失败时为 null）。
  final DateTime? publishedAt;

  /// 第一个 `.apk` asset 的下载直链；没有则为 null。
  ///
  /// 仅用于在弹窗里展示；按钮仍然跳 [htmlUrl]（用户能看到全部 assets 与
  /// 校验信息，也更符合公开仓库的分发习惯）。
  final String? apkUrl;

  /// 展示用标题：优先 Release 名称，退回 tag。
  String get displayTitle => name.trim().isEmpty ? tagName : name.trim();

  /// 从 GitHub API 的 JSON body 构造。
  ///
  /// **字段缺失或类型不符时返回 null 而不是抛异常** —— 上游 JSON 结构
  /// 一旦变化，更新检测应该静默失效，不能影响主流程。
  static ReleaseInfo? fromJson(Object? json) {
    if (json is! Map) return null;
    final tag = json['tag_name'];
    if (tag is! String || tag.trim().isEmpty) return null;

    // html_url 缺失时用 tag 拼一个兜底地址，保证「去下载」始终可点。
    final html = json['html_url'];
    final htmlUrl = (html is String && html.trim().isNotEmpty)
        ? html.trim()
        : 'https://github.com/Jingbing1030/nem/releases/tag/${tag.trim()}';

    final name = json['name'];
    final body = json['body'];
    final published = json['published_at'];

    return ReleaseInfo(
      tagName: tag.trim(),
      htmlUrl: htmlUrl,
      name: name is String ? name : '',
      body: body is String ? body : '',
      publishedAt: published is String ? DateTime.tryParse(published) : null,
      apkUrl: _firstApkUrl(json['assets']),
    );
  }

  static String? _firstApkUrl(Object? assets) {
    if (assets is! List) return null;
    for (final a in assets) {
      if (a is! Map) continue;
      final url = a['browser_download_url'];
      if (url is String && url.toLowerCase().endsWith('.apk')) {
        return url;
      }
    }
    return null;
  }
}
