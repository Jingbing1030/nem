import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// 哈希工具：内容寻址存储与传输校验都用它。
class Hashing {
  Hashing._();

  /// 计算 SHA-256，返回小写十六进制字符串（图片文件名即此值）。
  static String sha256Hex(List<int> bytes) =>
      sha256.convert(bytes).toString();

  /// 计算 SHA-1，返回十六进制字符串。
  static String sha1Hex(List<int> bytes) => sha1.convert(bytes).toString();

  /// 计算字节的 SHA-256 原始摘要。
  static Uint8List sha256Bytes(List<int> bytes) =>
      Uint8List.fromList(sha256.convert(bytes).bytes);

  /// 计算文件的 SHA-256（流式，避免大图整块读进内存）。
  static Future<String> sha256File(File file) async {
    final digest = await sha256.bind(file.openRead()).first;
    return digest.toString();
  }

  /// 校验字节内容是否匹配期望的 SHA-256 十六进制值。
  static bool matchesSha256(List<int> bytes, String expectedHex) =>
      sha256Hex(bytes).toLowerCase() == expectedHex.toLowerCase();

  /// 计算 UTF-8 文本的 SHA-256（笔记 content_hash 用）。
  static String contentHash(String text) => sha256Hex(utf8.encode(text));

  /// 计算 HMAC-SHA256 原始字节（配对证明用）。
  static Uint8List hmacSha256(List<int> key, List<int> message) =>
      Uint8List.fromList(Hmac(sha256, key).convert(message).bytes);

  /// 计算 HMAC-SHA256 的 base64 编码（配对证明的 wire 格式）。
  static String hmacSha256Base64(List<int> key, List<int> message) =>
      base64.encode(hmacSha256(key, message));

  /// 定长时间比较两个字节序列（变更 9：所有 HMAC / tag 比较必须恒定时间）。
  static bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// 定长时间比较两个 base64 字符串（先解码再比较，避免长度泄漏之外的时序差异）。
  static bool constantTimeEqualsB64(String a, String b) {
    try {
      return constantTimeEquals(base64.decode(a), base64.decode(b));
    } catch (_) {
      return false;
    }
  }

  /// 计算 HMAC-SHA1 原始字节（TOTP 用）。
  static Uint8List hmacSha1(List<int> key, List<int> message) =>
      Uint8List.fromList(
        Hmac(sha1, key).convert(message).bytes,
      );

  /// 计算 HMAC-SHA1 十六进制值。
  static String hmacSha1Hex(List<int> key, List<int> message) =>
      Hmac(sha1, key).convert(message).toString();

  /// UTF-8 编码辅助。
  static List<int> utf8Bytes(String s) => utf8.encode(s);
}
