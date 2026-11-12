/// 局域网记事本核心库。
///
/// 本包**不依赖 Flutter**，只做与平台无关的纯逻辑：
/// 加密（AES-GCM / PBKDF2）、TOTP、哈希、重放防护、WS 消息信封、同步冲突解决。
/// 这样可以脱离 Flutter 工具链直接在原生 Dart 上跑单元测试。
library;

export 'src/crypto/aes_gcm.dart';
export 'src/crypto/hashing.dart';
export 'src/crypto/kdf.dart';
export 'src/crypto/nonce_cache.dart';
export 'src/crypto/payload.dart';
export 'src/crypto/random_bytes.dart';
export 'src/crypto/totp.dart';
export 'src/protocol/envelope.dart';
export 'src/protocol/messages.dart';
export 'src/protocol/pairing.dart';
export 'src/sync/models.dart';
export 'src/sync/patch_util.dart';
export 'src/sync/planner.dart';
export 'src/version/version_vector.dart';
export 'src/notes/notes.dart';
export 'package:pointycastle/api.dart' show InvalidCipherTextException;
