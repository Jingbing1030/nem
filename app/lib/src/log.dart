import 'package:flutter/foundation.dart';

/// 日志工具。
///
/// **脱敏约定**（PROTOCOL.md 第 7 节）：密钥、配对码、笔记正文永不入日志。
/// 因此这里只提供结构化、可审计的少量输出，且仅在 debug 模式生效。
class Log {
  Log._();

  static const String _tag = 'LANNotepad';

  /// 仅在 debug 构建中输出。
  static void debug(String message) {
    if (kDebugMode) {
      debugPrint('[$_tag] $message');
    }
  }

  /// 记录密文材料时只暴露 nonce 前 8 字节，便于定位重放问题而不泄漏内容。
  static String noncePrefix(List<int> nonce) {
    final n = nonce.take(8).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '$n…';
  }

  /// 记录错误（不带敏感载荷）。
  static void error(String message, [Object? error]) {
    if (kDebugMode) {
      debugPrint('[$_tag][ERROR] $message${error == null ? '' : ': $error'}');
    }
  }
}
