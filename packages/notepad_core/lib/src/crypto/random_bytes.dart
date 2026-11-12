import 'dart:math' as math;
import 'dart:typed_data';

/// 密码学安全随机字节。
///
/// 抽成独立单元，便于加密模块、IV 生成、TOTP 共用，也便于测试替换。
class SecureRandomBytes {
  SecureRandomBytes._();

  static final math.Random _random = math.Random.secure();

  /// 生成 [length] 个安全随机字节。
  static Uint8List generate(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }
}
