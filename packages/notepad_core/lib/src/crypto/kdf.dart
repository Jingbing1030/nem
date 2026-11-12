import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'random_bytes.dart';

/// 密钥派生（PBKDF2-HMAC-SHA256）。
///
/// 参数按需求文档固定，不得自行调整：
/// - PRF 为 `HMac(SHA256Digest(), 64)`
/// - 派生密钥长度固定 32 字节
/// - 配对握手盐 `notepad_pair_v1`，迭代 100000
/// - 会话盐 `notepad_session_v1`，迭代 10000
class Kdf {
  Kdf._();

  /// 配对握手盐。
  static const String pairSalt = 'notepad_pair_v1';

  /// 会话盐。
  static const String sessionSalt = 'notepad_session_v1';

  /// TOTP 密钥派生盐。
  ///
  /// 文档未固定该值（第 4.4 节只写了「TOTP 用 HMAC-SHA1，兼容 RFC 6238」），
  /// 此处选型并写入 PROTOCOL.md。
  static const String totpSalt = 'notepad_totp_v1';

  static const int pairIterations = 100000;
  static const int sessionIterations = 10000;
  static const int totpIterations = 10000;

  /// 派生密钥长度（字节）。
  static const int derivedKeyLength = 32;

  /// 通用 PBKDF2-HMAC-SHA256。
  static Uint8List pbkdf2({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    int keyLength = derivedKeyLength,
  }) {
    final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
      ..init(Pbkdf2Parameters(
        Uint8List.fromList(salt),
        iterations,
        keyLength,
      ));
    return derivator.process(Uint8List.fromList(password));
  }

  /// 由 6 位配对码派生握手密钥。
  static Uint8List pairKey(String code) => pbkdf2(
        password: utf8.encode(code),
        salt: utf8.encode(pairSalt),
        iterations: pairIterations,
      );

  /// 由 masterKey 派生会话密钥。
  ///
  /// 约定：masterKey 以其 base64url 字符串形式参与派生（见 PROTOCOL.md），
  /// 这样收发两端输入字节完全一致，不依赖解码细节。
  static Uint8List sessionKey(String masterKeyB64Url) => pbkdf2(
        password: utf8.encode(masterKeyB64Url),
        salt: utf8.encode(sessionSalt),
        iterations: sessionIterations,
      );

  /// 由 masterKey 派生 TOTP 密钥（32 字节）。
  static Uint8List totpSecret(String masterKeyB64Url) => pbkdf2(
        password: utf8.encode(masterKeyB64Url),
        salt: utf8.encode(totpSalt),
        iterations: totpIterations,
      );

  /// 生成新的 128 位 masterKey，编码为 base64url（无填充）。
  static String generateMasterKey() {
    final bytes = SecureRandomBytes.generate(16);
    return base64Url.encode(bytes).replaceAll('=', '');
  }
}
