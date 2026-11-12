/// 协议消息类型与载荷字段名常量。
///
/// 与 PROTOCOL.md 一一对应，避免代码里散落魔法字符串。
class MsgType {
  MsgType._();

  // 握手
  static const String pairRequest = 'pair_request';
  static const String pairSuccess = 'pair_success';
  static const String pairFail = 'pair_fail';
  static const String fastAuth = 'fast_auth';
  static const String authOk = 'auth_ok';

  // 笔记
  /// 连接后交换摘要（含 versionVector / contentHash，不含正文）——变更 6.2
  static const String noteSummary = 'note_summary';
  /// 兼容旧名（第一版的 note_list）。新代码请用 [noteSummary]。
  static const String noteList = 'note_list';
  /// 增量同步
  static const String notePatch = 'note_patch';
  /// patch 应用成功
  static const String notePatchAck = 'note_patch_ack';
  /// 版本不匹配，降级为全量
  static const String notePatchNack = 'note_patch_nack';
  /// 大文件块哈希清单（≥256KB）
  static const String noteChunkManifest = 'note_chunk_manifest';
  /// 请求缺失块
  static const String noteChunkRequest = 'note_chunk_request';
  /// 推送单个块
  static const String noteChunkPush = 'note_chunk_push';
  static const String notePull = 'note_pull';
  static const String notePush = 'note_push';
  static const String noteDelete = 'note_delete';

  // 图片
  static const String imageManifest = 'image_manifest';
  static const String imageRequest = 'image_request';
  static const String imageChunk = 'image_chunk';
  static const String imageComplete = 'image_complete';

  // 心跳
  static const String ping = 'ping';
  static const String pong = 'pong';
}

/// 载荷字段名。
class Field {
  Field._();

  static const String code = 'code';
  static const String clientTime = 'clientTime';
  static const String deviceId = 'deviceId';
  static const String deviceName = 'deviceName';
  static const String masterKey = 'masterKey';
  static const String reason = 'reason';
  static const String serverDeviceId = 'serverDeviceId';
  static const String notes = 'notes';
  static const String noteId = 'noteId';
  static const String title = 'title';
  static const String updatedAt = 'updatedAt';
  static const String content = 'content';
  static const String imageHashes = 'imageHashes';
  static const String hashes = 'hashes';
  static const String hash = 'hash';
  static const String seq = 'seq';
  static const String total = 'total';
  static const String data = 'data';
  static const String ts = 'ts';
  static const String nonce = 'nonce';
  static const String hmac = 'hmac';
  static const String versionVector = 'versionVector';
  static const String fromVersionVector = 'fromVersionVector';
  static const String toVersionVector = 'toVersionVector';
  static const String patch = 'patch';
  static const String chunkHashes = 'chunkHashes';
  static const String chunkHash = 'chunkHash';
  static const String contentHash = 'contentHash';
  static const String baseHash = 'baseHash';
}

/// 协议常量。
class ProtocolConst {
  ProtocolConst._();

  /// mDNS 服务类型。
  static const String serviceType = '_notepad._tcp.local';

  /// 心跳间隔（秒）。
  static const int heartbeatSeconds = 30;

  /// 配对码 TOTP 步长（秒）。
  static const int totpPeriod = 30;

  /// 配对码 TOTP 校验窗口（±1 步）。
  static const int totpWindow = 1;

  /// 配对码位数。
  static const int pairingCodeDigits = 6;

  /// clientTime 容忍偏差（秒）。
  static const int clockToleranceSeconds = 60;

  /// 图片分块大小上限（字节），128KB。
  static const int imageChunkSize = 128 * 1024;

  /// 同一 IP 连续配对失败几次后锁定。
  static const int pairingFailureLimit = 3;

  /// 触发锁定后的锁定时长（秒）。
  static const int pairingLockoutSeconds = 60;

  /// patch 体积超过全量的该比例时改发全量（变更 6.4）。
  static const double patchSizeRatioLimit = 0.7;

  /// 大文件块级同步阈值（变更 6.2）。
  static const int chunkSyncThresholdBytes = 256 * 1024;

  /// 编辑防抖（毫秒，变更 6.4）。
  static const int editDebounceMs = 500;

  /// 编辑节流（毫秒，变更 6.4）。
  static const int editThrottleMs = 2000;

  /// 配对请求 nonce 缓存时长（秒，变更 5）。
  static const int pairNonceTtlSeconds = 60;

  /// 重放防护缓存条数。
  static const int nonceCacheSize = 200;

  /// 图片压缩长边上限（像素）。
  static const int imageMaxDimension = 1920;

  /// 图片压缩质量。
  static const int imageQuality = 85;

  /// 笔记摘要长度。
  static const int excerptLength = 100;
}
