import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'payload.dart';
import 'random_bytes.dart';

/// AES-256-GCM 加解密。
///
/// 参数按需求文档固定，不得自行调整：
/// - IV 12 字节随机
/// - tag 16 字节（128 bit）
/// - 必须走 [AEADParameters]，不能用 ParametersWithIV
///   （后者不会把 tag 纳入校验，篡改检测会失效）
class AesGcm {
  AesGcm._();

  /// IV / nonce 长度（字节）。
  static const int ivLength = 12;

  /// 认证标签长度（字节）。
  static const int tagLength = 16;

  /// 认证标签长度（bit）。
  static const int tagBits = tagLength * 8;

  /// 密钥长度（字节），AES-256。
  static const int keyLength = 32;

  /// 加密，返回 nonce / 密文 / tag 三段。
  static EncryptedPayload encrypt(
    Uint8List key,
    List<int> plaintext, {
    Uint8List? nonce,
    Uint8List? aad,
  }) {
    _assertKey(key);
    final iv = nonce ?? SecureRandomBytes.generate(ivLength);
    if (iv.length != ivLength) {
      throw ArgumentError('AES-GCM IV 必须为 $ivLength 字节，收到 ${iv.length}');
    }

    final cipher = GCMBlockCipher(AESEngine())
      ..init(true, AEADParameters(KeyParameter(key), tagBits, iv, aad ?? Uint8List(0)));
    final out = cipher.process(Uint8List.fromList(plaintext));
    // GCM 的输出布局是 ciphertext || tag。
    final ct = Uint8List.sublistView(out, 0, out.length - tagLength);
    final tag = Uint8List.sublistView(out, out.length - tagLength);
    return EncryptedPayload(
      nonce: iv,
      ciphertext: Uint8List.fromList(ct),
      tag: Uint8List.fromList(tag),
    );
  }

  /// 解密。密文或 tag 被篡改时抛 [InvalidCipherTextException]。
  static Uint8List decrypt(
    Uint8List key,
    EncryptedPayload payload, {
    Uint8List? aad,
  }) {
    _assertKey(key);
    if (payload.tag.length != tagLength) {
      throw ArgumentError(
        'AES-GCM tag 必须为 $tagLength 字节，收到 ${payload.tag.length}',
      );
    }
    if (payload.nonce.length != ivLength) {
      throw ArgumentError(
        'AES-GCM IV 必须为 $ivLength 字节，收到 ${payload.nonce.length}',
      );
    }

    final cipher = GCMBlockCipher(AESEngine())
      ..init(false, AEADParameters(KeyParameter(key), tagBits, payload.nonce, aad ?? Uint8List(0)));
    // tag 校验失败会在这一步抛 InvalidCipherTextException。
    return cipher.process(payload.joined);
  }

  /// 解密失败返回 null 而不是抛异常。
  ///
  /// 用于「能否解密本身即认证」的场景（如已配对设备重连的 fast_auth）。
  static Uint8List? tryDecrypt(
    Uint8List key,
    EncryptedPayload payload, {
    Uint8List? aad,
  }) {
    try {
      return decrypt(key, payload, aad: aad);
    } on InvalidCipherTextException {
      return null;
    } on ArgumentError {
      return null;
    }
  }

  static void _assertKey(Uint8List key) {
    if (key.length != keyLength) {
      throw ArgumentError('AES-256 密钥必须为 $keyLength 字节，收到 ${key.length}');
    }
  }
}
