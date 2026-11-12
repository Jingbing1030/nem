import 'dart:convert';
import 'dart:typed_data';

import '../crypto/aes_gcm.dart';
import '../crypto/nonce_cache.dart';
import '../crypto/payload.dart';

/// WS 消息信封，所有消息统一格式。
///
/// ```json
/// { "type": "...", "nonce": "<base64,12B>", "payload": "<base64,GCM密文>", "tag": "<base64,16B>" }
/// ```
class Envelope {
  const Envelope({required this.type, required this.payload});

  /// 消息类型（明文，便于路由与日志；不含敏感内容）。
  final String type;

  /// 加密载荷。
  final EncryptedPayload payload;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': type,
        'nonce': payload.nonceB64,
        'payload': payload.ciphertextB64,
        'tag': payload.tagB64,
      };

  String encode() => jsonEncode(toJson());

  static Envelope fromJson(Map<String, dynamic> json) => Envelope(
        type: json['type'] as String,
        payload: EncryptedPayload.fromBase64(
          nonce: json['nonce'] as String,
          payload: json['payload'] as String,
          tag: json['tag'] as String,
        ),
      );

  static Envelope decode(String raw) =>
      fromJson(jsonDecode(raw) as Map<String, dynamic>);

  @override
  String toString() => 'Envelope(type=$type, $payload)';
}

/// 解密/重放校验失败。
class EnvelopeException implements Exception {
  EnvelopeException(this.message);
  final String message;
  @override
  String toString() => 'EnvelopeException: $message';
}

/// 把密钥、重放缓存和信封编解码绑在一起的会话对象。
///
/// 所有收到的消息都必须经由 [open] 通过 GCM tag 校验与 nonce 重放检查，
/// 任一失败即抛 [EnvelopeException]，调用方据此丢弃消息并断开连接。
class SecureSession {
  SecureSession({required this.key, NonceCache? nonceCache})
      : nonceCache = nonceCache ?? NonceCache();

  /// 32 字节会话密钥（或握手密钥）。
  final Uint8List key;

  /// 重放防护缓存。
  final NonceCache nonceCache;

  /// 组装并加密一条消息。
  Envelope seal(String type, Map<String, dynamic> body) {
    final plaintext = utf8.encode(jsonEncode(body));
    return Envelope(type: type, payload: AesGcm.encrypt(key, plaintext));
  }

  /// 校验并解密一条消息。
  ///
  /// 顺序很重要：先做 GCM 认证（密文不可信），再做重放检查。
  /// 与 [open] 相同，但失败时返回 null 而不是抛异常。
  ///
  /// 用于「枚举候选密钥、看哪个能解开」这类需要主动试错的场景
  /// （配对握手即如此）。
  Map<String, dynamic>? openOrNull(Envelope envelope) {
    try {
      return open(envelope);
    } on EnvelopeException {
      return null;
    }
  }

  Map<String, dynamic> open(Envelope envelope) {
    final cleartext = AesGcm.tryDecrypt(key, envelope.payload);
    if (cleartext == null) {
      throw EnvelopeException('GCM 认证失败（密文被篡改或密钥不匹配）type=${envelope.type}');
    }
    if (!nonceCache.checkAndStore(envelope.payload.nonce)) {
      throw EnvelopeException('nonce 重放，已丢弃 type=$envelope.type');
    }
    try {
      return jsonDecode(utf8.decode(cleartext)) as Map<String, dynamic>;
    } on FormatException catch (e) {
      throw EnvelopeException('载荷不是合法 JSON: ${e.message}');
    }
  }
}
