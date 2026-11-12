import 'dart:convert';
import 'dart:typed_data';

/// AES-GCM 密文的三段式载体：nonce / 密文 / tag。
///
/// 对应协议信封（见 PROTOCOL.md）里的 `nonce` / `payload` / `tag` 三个 base64 字段。
class EncryptedPayload {
  const EncryptedPayload({
    required this.nonce,
    required this.ciphertext,
    required this.tag,
  });

  /// 12 字节随机 IV。
  final Uint8List nonce;

  /// AES-GCM 密文（不含 tag）。
  final Uint8List ciphertext;

  /// 16 字节认证标签。
  final Uint8List tag;

  String get nonceB64 => base64.encode(nonce);
  String get ciphertextB64 => base64.encode(ciphertext);
  String get tagB64 => base64.encode(tag);

  /// 从三个 base64 字段还原。
  static EncryptedPayload fromBase64({
    required String nonce,
    required String payload,
    required String tag,
  }) {
    return EncryptedPayload(
      nonce: base64.decode(nonce),
      ciphertext: base64.decode(payload),
      tag: base64.decode(tag),
    );
  }

  /// 拼成 GCM 解密需要的 `ciphertext || tag` 形式。
  Uint8List get joined => Uint8List.fromList(<int>[...ciphertext, ...tag]);

  @override
  String toString() => 'EncryptedPayload(nonce=${nonce.length}B, '
      'ct=${ciphertext.length}B, tag=${tag.length}B)';
}
