import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../log.dart';
import 'release_info.dart';
import 'update_checker.dart';
import 'update_service.dart';

/// 全局共用的 GitHub Release 查询客户端（内含 6 小时结果缓存，省未认证配额）。
final updateCheckerProvider = Provider<UpdateChecker>((ref) {
  final checker = UpdateChecker();
  ref.onDispose(checker.dispose);
  return checker;
});

/// 更新检测服务。
///
/// **不做成 override 注入**：它只依赖 shared_preferences（`main()` 里
/// `ConfigStore.open()` 已经初始化过插件通道），因此延迟到真正需要时再取，
/// 不必改动 `main()` 的基础设施装配。
final updateServiceProvider = FutureProvider<UpdateService>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  return UpdateService(
    prefs: prefs,
    checker: ref.watch(updateCheckerProvider),
  );
});

/// 「去下载」按钮的跳转实现（可注入以便将来测试）。
Future<bool> _defaultLauncher(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

/// 弹出更新提示。
///
/// 交互约定：
/// - 「去下载」→ 打开 Release 页面（外部浏览器）；
/// - 「稍后」  → 本次不再提示，下次冷启动仍会检查；
/// - 「跳过此版本」→ 写入 shared_preferences，**该版本**此后不再提示
///   （更高版本仍会提示）。
Future<void> showUpdateDialog(
  BuildContext context, {
  required ReleaseInfo info,
  required UpdateService service,
  Future<bool> Function(Uri uri)? launcher,
}) async {
  final launch = launcher ?? _defaultLauncher;

  final action = await showDialog<_UpdateAction>(
    context: context,
    builder: (ctx) => _UpdateDialog(info: info),
  );
  if (action == null) return;

  switch (action) {
    case _UpdateAction.download:
      var ok = false;
      try {
        ok = await launch(Uri.parse(info.htmlUrl));
      } catch (e) {
        // 没有浏览器 / 无法解析 scheme 都走这里，不能把异常抛到 UI 之外。
        Log.debug('打开 Release 页面失败：$e');
      }
      if (!ok && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('无法打开浏览器，请手动访问 ${info.htmlUrl}')),
        );
      }
    case _UpdateAction.later:
      break;
    case _UpdateAction.skip:
      await service.skip(info.tagName);
  }
}

enum _UpdateAction { download, later, skip }

/// 更新说明的最大展示长度（超长 Release body 截断，避免弹窗被撑爆）。
const int _maxBodyChars = 500;

class _UpdateDialog extends StatelessWidget {
  const _UpdateDialog({required this.info});

  final ReleaseInfo info;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = _formatBody(info.body);

    return AlertDialog(
      title: Text('发现新版本 ${info.tagName}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (info.displayTitle != info.tagName)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  info.displayTitle,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            if (notes.isEmpty)
              Text(
                '该版本未提供更新说明。',
                style: TextStyle(color: theme.colorScheme.outline),
              )
            else
              Text(notes, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(_UpdateAction.skip),
          child: const Text('跳过此版本'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_UpdateAction.later),
          child: const Text('稍后'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_UpdateAction.download),
          child: const Text('去下载'),
        ),
      ],
    );
  }

  /// 截断长文本、压缩连续空行；去掉 Markdown 里纯分隔线一类的噪声行头。
  static String _formatBody(String raw) {
    final text = raw.replaceAll('\r\n', '\n').trim();
    if (text.isEmpty) return '';
    // 三个以上连续换行压成一个空行。
    final compact = text.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    if (compact.length <= _maxBodyChars) return compact;
    return '${compact.substring(0, _maxBodyChars).trimRight()}…';
  }
}
