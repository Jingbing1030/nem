import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'update_dialog.dart';
import 'update_service.dart';

/// 启动时的「检查更新」挂载点。
///
/// **为什么是包一层 Widget 而不是写进 `initState`**：
/// 检查更新是**可选功能**，绝不能影响首屏。这里做了三重保证：
/// 1. **延迟 [delay] 后才发起**（默认 1.2 秒），让 `NotesListPage` 的
///    AsyncNotifier 先把笔记读出来、首帧渲染完；
/// 2. **完全异步**，不 await 任何 UI 关键路径，不阻塞 build；
/// 3. **任何异常都被 [UpdateService.checkForUpdate] 吞掉**，这里只做
///    防御性兜底 —— 一个更新提示弹不出来，不该让用户看见报错。
///
/// 冷启动只跑一次（State 只 build 一次）；热重载/重建不会重复请求。
class StartupUpdateCheck extends ConsumerStatefulWidget {
  const StartupUpdateCheck({
    super.key,
    required this.child,
    this.delay = const Duration(milliseconds: 1200),
  });

  final Widget child;

  /// 首次检查的延迟。
  final Duration delay;

  @override
  ConsumerState<StartupUpdateCheck> createState() => _StartupUpdateCheckState();
}

class _StartupUpdateCheckState extends ConsumerState<StartupUpdateCheck> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.delay, _run);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    try {
      // 服务本身是异步构造的（首次要拿 SharedPreferences 实例）。
      final service = await ref.read(updateServiceProvider.future);
      if (!mounted) return;

      final info = await service.checkForUpdate();
      if (info == null || !mounted) return;

      await showUpdateDialog(context, info: info, service: service);
    } catch (_) {
      // 静默：更新提示失败不影响任何主流程。
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
