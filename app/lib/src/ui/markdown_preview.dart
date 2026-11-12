import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

/// Markdown 预览。
///
/// 自定义 `imageBuilder` 是需求 5.2 的硬性要求，四种情况分别处理：
/// 1. http/https → [Image.network]
/// 2. 相对路径 → 拼到笔记库根目录下读文件，存在则 [Image.file]，点击全屏预览
/// 3. 缺失 → 灰色占位 + 「图片缺失」+「重新导入」按钮
/// 4. 绝对路径 / file:// → 尝试读取，失败给同样的占位
class MarkdownPreview extends StatelessWidget {
  const MarkdownPreview({
    super.key,
    required this.data,
    required this.notesRoot,
    this.onReimport,
    this.selectable = true,
  });

  /// Markdown 正文。
  final String data;

  /// 笔记库根目录（相对图片路径基于它解析）。
  final String notesRoot;

  /// 「重新导入」回调，参数是原始引用的相对路径。
  final void Function(String ref)? onReimport;

  final bool selectable;

  /// 支持的扩展：表格、删除线、任务列表、脚注、emoji。
  ///
  /// 直接用 markdown 包内置的 gitHubWeb 扩展集（它已包含
  /// TableSyntax / StrikethroughSyntax / UnorderedListWithCheckboxSyntax 等），
  /// 避免手工组合语法列表时漏项或重复。
  static final md.ExtensionSet extensionSet = md.ExtensionSet.gitHubWeb;

  @override
  Widget build(BuildContext context) {
    final body = MarkdownBody(
      data: data,
      selectable: selectable,
      extensionSet: extensionSet,
      imageBuilder: (uri, title, alt) => _buildImage(context, uri, alt),
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        code: TextStyle(
          fontFamily: 'monospace',
          fontSize: 13,
          backgroundColor: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.5),
        ),
        codeblockDecoration: BoxDecoration(
          color: Theme.of(context)
              .colorScheme
              .surfaceContainerHighest
              .withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(6),
        ),
      ),
    );
    return body;
  }

  Widget _buildImage(BuildContext context, Uri uri, String? alt) {
    final raw = uri.toString();

    // 1. 网络图片
    if (uri.scheme == 'http' || uri.scheme == 'https') {
      return _framed(
        context,
        Image.network(
          raw,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) =>
              _missing(context, raw, reason: '网络图片加载失败'),
        ),
      );
    }

    // 4. 绝对路径 / file:// —— 需求允许尝试读取，失败则给占位
    if (uri.scheme == 'file' || raw.startsWith('/') || p.isAbsolute(raw)) {
      final path = uri.scheme == 'file' ? uri.toFilePath() : raw;
      final f = File(path);
      if (f.existsSync()) {
        return _tappable(context, f, raw);
      }
      return _missing(context, raw, reason: '绝对路径读取失败');
    }

    // 2. 相对路径：基于笔记库根目录解析
    final file = File(p.join(notesRoot, uri.path));
    if (file.existsSync()) {
      return _tappable(context, file, raw);
    }

    // 3. 缺失
    return _missing(context, raw, reason: '图片缺失');
  }

  Widget _tappable(BuildContext context, File file, String ref) => _framed(
        context,
        GestureDetector(
          onTap: () => _openFullscreen(context, file),
          child: Image.file(
            file,
            fit: BoxFit.contain,
            errorBuilder: (_, __, ___) =>
                _missing(context, ref, reason: '图片损坏或无法解码'),
          ),
        ),
      );

  Widget _framed(BuildContext context, Widget child) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: child,
        ),
      );

  /// 缺失占位：灰色 + 说明 + 「重新导入」。
  Widget _missing(BuildContext context, String ref, {required String reason}) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.broken_image_outlined, color: scheme.outline),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  reason,
                  style: TextStyle(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  ref,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.outline,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ),
          if (onReimport != null)
            TextButton.icon(
              onPressed: () => onReimport!(ref),
              icon: const Icon(Icons.upload_file, size: 16),
              label: const Text('重新导入'),
            ),
        ],
      ),
    );
  }

  void _openFullscreen(BuildContext context, File file) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _FullscreenImage(file: file),
      ),
    );
  }
}

/// 全屏图片预览：支持双指缩放与拖动。
class _FullscreenImage extends StatelessWidget {
  const _FullscreenImage({required this.file});

  final File file;

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
        body: Center(
          child: InteractiveViewer(
            minScale: 1,
            maxScale: 6,
            child: Image.file(
              file,
              fit: BoxFit.contain,
              errorBuilder: (_, __, ___) => const Text(
                '无法显示该图片',
                style: TextStyle(color: Colors.white70),
              ),
            ),
          ),
        ),
      );
}
