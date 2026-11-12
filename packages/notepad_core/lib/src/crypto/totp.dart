import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// TOTP（RFC 6238），底层 HMAC-SHA1（RFC 4226 HOTP）。
///
/// 参数按需求文档固定：6 位码、30 秒步长、校验窗口 ±1。
/// 实现同时暴露 HOTP，便于直接用 RFC 4226/6238 官方测试向量验证。
class Totp {
  Totp._();

  /// 时间步长（秒）。
  static const int period = 30;

  /// 验证窗口：±1 步（即 ±30s）。
  static const int defaultWindow = 1;

  /// 配对码位数。
  static const int digits = 6;

  /// HOTP：由计数器和密钥生成 [digits] 位码。
  static String hotp(List<int> secret, int counter, {int digits = 6}) {
    // 计数器按 RFC 4226 规定为 8 字节大端。
    final msg = Uint8List(8);
    var c = counter;
    for (var i = 7; i >= 0; i--) {
      msg[i] = c & 0xff;
      c >>= 8;
    }

    final hash = Hmac(sha1, secret).convert(msg).bytes;

    // 动态截断（DT）。
    final offset = hash[hash.length - 1] & 0x0f;
    final binary = ((hash[offset] & 0x7f) << 24) |
        ((hash[offset + 1] & 0xff) << 16) |
        ((hash[offset + 2] & 0xff) << 8) |
        (hash[offset + 3] & 0xff);

    final otp = binary % _pow10(digits);
    return otp.toString().padLeft(digits, '0');
  }

  /// TOTP：由时间戳生成码。
  static String totp(
    List<int> secret,
    DateTime time, {
    int digits = 6,
    int period = 30,
  }) {
    final counter = time.toUtc().millisecondsSinceEpoch ~/ 1000 ~/ period;
    return hotp(secret, counter, digits: digits);
  }

  /// 校验码是否正确，允许 ±[window] 个时间步的漂移。
  ///
  /// 校验时使用**发送方/客户端提供的时间**（协议规定 clientTime），
  /// 服务端在此基础上做窗口容忍。
  static bool verify(
    String code,
    List<int> secret,
    DateTime time, {
    int window = defaultWindow,
    int digits = 6,
    int period = 30,
  }) {
    if (code.length != digits) return false;
    for (var offset = -window; offset <= window; offset++) {
      final candidate = totp(
        secret,
        time.add(Duration(seconds: offset * period)),
        digits: digits,
        period: period,
      );
      if (_constantTimeEquals(candidate, code)) return true;
    }
    return false;
  }

  /// 当前时间步距离下一个码刷新的剩余秒数（UI 倒计时用）。
  static int secondsRemaining(DateTime time, {int period = 30}) {
    final seconds = time.toUtc().millisecondsSinceEpoch ~/ 1000;
    return period - (seconds % period);
  }

  /// 定长时间比较，避免时序侧信道。
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  static int _pow10(int n) {
    var r = 1;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }
}
