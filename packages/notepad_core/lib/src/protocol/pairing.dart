import 'dart:convert';
import 'dart:typed_data';

import '../crypto/hashing.dart';
import '../crypto/kdf.dart';
import '../crypto/nonce_cache.dart';
import '../crypto/random_bytes.dart';
import '../crypto/totp.dart';
import 'envelope.dart';
import 'messages.dart';

/// 配对握手（变更 5：HMAC 证明版）。
///
/// ## 第一版的缺陷
///
/// `pair_request` 的载荷含 `code`，同时又要求用 `PBKDF2(code)` 加密该消息 ——
/// 服务端解密前不知道 `code`，构成循环依赖。
///
/// ## 最终版
///
/// `pair_request` **明文**发送（不含 code、不含任何机密），用 HMAC 证明持有配对码：
///
/// ```json
/// {
///   "type": "pair_request",
///   "clientTime": 1712345678000,
///   "nonce": "<base64 16B>",
///   "deviceId": "<uuid>",
///   "deviceName": "B的手机",
///   "hmac": "<base64 HMAC-SHA256(PBKDF2(code), 'clientTime|nonce|deviceId|deviceName')>"
/// }
/// ```
///
/// - `code` **不出现在载荷里**；
/// - 服务端遍历当前时间 ±1 窗口的 3 个候选 code，逐个算 HMAC 并**恒定时间比较**；
/// - 匹配 → 用命中 code 的 PBKDF2 派生密钥加密 masterKey，回 `pair_success`；
/// - 不匹配 → 明文 `pair_fail` + 关闭连接 + 同 deviceId 3 次锁 60s。
///
/// ## HMAC 输入为何包含 nonce 与 deviceId
///
/// - `nonce`：使每条请求唯一，配合 60s nonce 缓存即可**拒绝重放**；
/// - `deviceId` / `deviceName`：把证明绑定到具体设备，防止换设备重放。
///
/// ## 注意：HMAC 与 AES-GCM 的「双重验证」
///
/// 需求文档把 HMAC 作为主要防线。本实现在此之上**额外**用被命中 code 派生的
/// 密钥加密 `pair_success`（文档要求如此），因此攻击者要拿到 masterKey，
/// 既要伪造 HMAC、又要解开 GCM —— 两把锁都由同一个 6 位码派生，
/// 但 GCM 的认证标签保证了响应无法被离线篡改。
class PairingHandshake {
  PairingHandshake._();

  /// `pair_request` 的 nonce 长度（16 字节，文档规定）。
  static const int requestNonceLength = 16;

  /// 配对结果状态。
  static const String ok = 'ok';
  static const String badCode = 'bad_code';
  static const String badTime = 'bad_time';
  static const String replayed = 'replayed';
  static const String malformed = 'malformed';

  /// HMAC 的输入串：`clientTime|nonce|deviceId|deviceName`（文档规定）。
  static String hmacMessage({
    required int clientTime,
    required String nonceB64,
    required String deviceId,
    required String deviceName,
  }) =>
      '$clientTime|$nonceB64|$deviceId|$deviceName';

  /// 由配对码计算 HMAC 证明。
  static String computeProof({
    required String code,
    required int clientTime,
    required String nonceB64,
    required String deviceId,
    required String deviceName,
  }) =>
      Hashing.hmacSha256Base64(
        Kdf.pairKey(code),
        utf8.encode(hmacMessage(
          clientTime: clientTime,
          nonceB64: nonceB64,
          deviceId: deviceId,
          deviceName: deviceName,
        )),
      );

  /// 客户端构造 `pair_request`（**明文 JSON，不加密**）。
  ///
  /// [nonce] 可注入以便测试；默认生成 16 字节安全随机数。
  static PairRequest buildRequest({
    required String code,
    required String deviceId,
    required String deviceName,
    required int clientTime,
    Uint8List? nonce,
  }) {
    final raw = nonce ?? SecureRandomBytes.generate(requestNonceLength);
    final nonceB64 = base64.encode(raw);
    return PairRequest(
      clientTime: clientTime,
      nonceB64: nonceB64,
      deviceId: deviceId,
      deviceName: deviceName,
      hmac: computeProof(
        code: code,
        clientTime: clientTime,
        nonceB64: nonceB64,
        deviceId: deviceId,
        deviceName: deviceName,
      ),
    );
  }

  /// 服务端校验 `pair_request`。
  ///
  /// [nowMillis] 用于确定 ±1 窗口的候选码；[clientTimeMillis] 来自请求本身
  /// （文档语义：用客户端时间在本机窗口内枚举候选）。
  /// [nonceCache] 用于重放拒绝（60s 窗口由调用方维护）。
  static PairingAttempt verifyRequest({
    required PairRequest request,
    required String masterKey,
    required int nowMillis,
    NonceCache? nonceCache,
  }) {
    // 1) 重放拒绝：同一 nonce 只接受一次。
    if (nonceCache != null) {
      final nonceBytes = _tryDecode(request.nonceB64);
      if (nonceBytes == null) {
        return const PairingAttempt(status: malformed);
      }
      if (!nonceCache.checkAndStore(nonceBytes)) {
        return const PairingAttempt(status: replayed);
      }
    }

    // 2) 时间合理性：clientTime 与本机时间偏差超过容忍范围直接拒。
    final drift = (nowMillis - request.clientTime).abs();
    if (drift > ProtocolConst.clockToleranceSeconds * 1000) {
      return const PairingAttempt(status: badTime);
    }

    // 3) 遍历 ±1 窗口的候选码，逐个算 HMAC 并恒定时间比较。
    final secret = Kdf.totpSecret(masterKey);
    final window = ProtocolConst.totpWindow;
    final period = ProtocolConst.totpPeriod;
    final digits = ProtocolConst.pairingCodeDigits;

    final claimed = _tryDecodeBase64String(request.hmac);

    for (var offset = -window; offset <= window; offset++) {
      final candidateTime = DateTime.fromMillisecondsSinceEpoch(
        nowMillis + offset * period * 1000,
        isUtc: true,
      );
      final code = Totp.totp(secret, candidateTime, digits: digits, period: period);
      final expected = Hashing.hmacSha256(
        Kdf.pairKey(code),
        utf8.encode(hmacMessage(
          clientTime: request.clientTime,
          nonceB64: request.nonceB64,
          deviceId: request.deviceId,
          deviceName: request.deviceName,
        )),
      );

      // 恒定时间比较（变更 9）。长度不等直接 false，不提前返回以免泄漏更多信息。
      final matches = claimed != null &&
          Hashing.constantTimeEquals(expected, claimed);

      if (matches) {
        return PairingAttempt(
          status: ok,
          key: Kdf.pairKey(code),
          matchedCode: code,
          request: request,
        );
      }
    }

    return const PairingAttempt(status: badCode);
  }

  /// 服务端回传 masterKey（AES-GCM 信封，用命中 code 派生的密钥加密）。
  static Envelope buildSuccess({
    required Uint8List handshakeKey,
    required String masterKey,
  }) =>
      SecureSession(key: handshakeKey).seal(
        MsgType.pairSuccess,
        <String, dynamic>{Field.masterKey: masterKey},
      );

  /// 客户端解开 `pair_success` 取回 masterKey。
  static String? openSuccess({
    required Uint8List handshakeKey,
    required Envelope envelope,
  }) {
    final body = SecureSession(key: handshakeKey).openOrNull(envelope);
    return body?[Field.masterKey] as String?;
  }

  /// 明文失败响应（文档规定 `pair_fail` 为明文 `{type, reason}`）。
  static Map<String, dynamic> buildFailure(String reason) => <String, dynamic>{
        'type': MsgType.pairFail,
        Field.reason: reason,
      };

  /// 当前应显示的配对码。
  static String currentCode(String masterKey, {DateTime? now}) => Totp.totp(
        Kdf.totpSecret(masterKey),
        now ?? DateTime.now(),
        digits: ProtocolConst.pairingCodeDigits,
        period: ProtocolConst.totpPeriod,
      );

  /// 配对码剩余有效秒数。
  static int secondsRemaining({DateTime? now}) =>
      Totp.secondsRemaining(now ?? DateTime.now(), period: ProtocolConst.totpPeriod);

  static Uint8List? _tryDecode(String s) {
    try {
      return base64.decode(s);
    } catch (_) {
      return null;
    }
  }

  static Uint8List? _tryDecodeBase64String(String s) {
    try {
      return base64.decode(s);
    } catch (_) {
      return null;
    }
  }
}

/// 明文 `pair_request` 载荷。
class PairRequest {
  const PairRequest({
    required this.clientTime,
    required this.nonceB64,
    required this.deviceId,
    required this.deviceName,
    required this.hmac,
  });

  /// 客户端时间（毫秒 Unix）。
  final int clientTime;

  /// 16 字节 nonce 的 base64。
  final String nonceB64;

  final String deviceId;
  final String deviceName;

  /// HMAC-SHA256 证明的 base64。
  final String hmac;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'type': MsgType.pairRequest,
        Field.clientTime: clientTime,
        Field.nonce: nonceB64,
        Field.deviceId: deviceId,
        Field.deviceName: deviceName,
        Field.hmac: hmac,
      };

  String encode() => jsonEncode(toJson());

  static PairRequest? fromJson(Map<String, dynamic> json) {
    final clientTime = json[Field.clientTime];
    final nonce = json[Field.nonce];
    final deviceId = json[Field.deviceId];
    final deviceName = json[Field.deviceName];
    final hmac = json[Field.hmac];
    if (clientTime is! int ||
        nonce is! String ||
        deviceId is! String ||
        deviceName is! String ||
        hmac is! String) {
      return null;
    }
    return PairRequest(
      clientTime: clientTime,
      nonceB64: nonce,
      deviceId: deviceId,
      deviceName: deviceName,
      hmac: hmac,
    );
  }
}

/// 服务端校验结果。
class PairingAttempt {
  const PairingAttempt({
    required this.status,
    this.key,
    this.matchedCode,
    this.request,
  });

  /// 见 [PairingHandshake] 的状态常量。
  final String status;

  /// 成功后由命中 code 派生的握手密钥。
  final Uint8List? key;

  /// 命中的配对码（**仅用于测试断言，不得写日志**）。
  final String? matchedCode;

  /// 原始请求。
  final PairRequest? request;

  bool get isOk => status == PairingHandshake.ok;
}
