import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:notepad_core/notepad_core.dart';

import '../log.dart';
import 'sync_engine.dart';

/// 连接所处的阶段。
enum PeerPhase {
  /// 尚未完成握手（此刻只有握手回调能动它）。
  handshake,

  /// 已完成认证，可使用会话密钥正常收发。
  ready,

  /// 已关闭。
  closed,
}

/// 一条对端连接：负责信封收发、心跳、重放防护，并把业务消息交给 [SyncEngine]。
///
/// **握手期间**不预设会话密钥，由上层回调按消息类型路由（变更 5 起是两条路径）：
/// - `pair_request` / `pair_fail` 是**明文 JSON**（HMAC 证明版），走 [onHandshakePlain]；
/// - `fast_auth` / `pair_success` 是**加密信封**，走 [onHandshakeEnvelope]。
///
/// 信封的 `type` 是明文，因此服务端**无需先解密**就能区分这两条路径。
class PeerSession {
  PeerSession({
    required this.socket,
    required this.remoteLabel,
    required this.engine,
    this.onHandshakeEnvelope,
    this.onHandshakePlain,
    this.onClosed,
  });

  final WebSocket socket;
  final String remoteLabel;
  final SyncEngine engine;

  /// 握手阶段收到的**加密**信封（未认证前）。
  final Future<void> Function(PeerSession, Envelope)? onHandshakeEnvelope;

  /// 握手阶段收到的**明文**消息（变更 5）。
  ///
  /// 返回 `true` 表示该消息已被消费；`false` 表示类型不认识（此时握手阶段会断开）。
  final Future<bool> Function(PeerSession, String, Map<String, dynamic>)?
      onHandshakePlain;

  /// 连接关闭回调。
  final void Function(PeerSession)? onClosed;

  Uint8List? _key;
  NonceCache? _nonceCache;
  StreamSubscription<dynamic>? _sub;
  Timer? _heartbeat;
  PeerPhase _phase = PeerPhase.handshake;

  /// 对端设备 id（握手成功后填充；也是同步基线的键）。
  String? remoteDeviceId;

  /// 对端设备名。
  String? remoteDeviceName;

  PeerPhase get phase => _phase;
  bool get isAuthenticated => _phase == PeerPhase.ready;
  bool get isClosed => _phase == PeerPhase.closed;

  /// 认证成功：切换到会话密钥并开始心跳。
  void activate(Uint8List sessionKey) {
    _key = sessionKey;
    _nonceCache = NonceCache();
    _phase = PeerPhase.ready;
    _startHeartbeat();
  }

  /// 握手期间发送一个**加密**信封（用握手密钥或会话密钥）。
  ///
  /// 与 [send] 不同，这里不做阶段校验，因为握手阶段尚未 `activate`。
  void sendHandshake(Envelope envelope) {
    try {
      socket.add(envelope.encode());
    } catch (e) {
      Log.error('握手消息发送失败', e);
      _teardown('发送失败: $e');
    }
  }

  /// 握手期间发送一条**明文**握手消息（`pair_request` / `pair_fail`）。
  ///
  /// 仅限不含机密的握手消息：配对码由 HMAC 证明持有，从不进入载荷
  /// （需求「pair_request 中无明文码」的硬约束）。
  void sendPlain(Map<String, dynamic> body) {
    try {
      socket.add(jsonEncode(body));
    } catch (e) {
      Log.error('握手明文发送失败', e);
      _teardown('发送失败: $e');
    }
  }

  /// 握手期间用指定密钥解一条消息（用于客户端收 `pair_success`）。
  Map<String, dynamic>? openHandshake(Uint8List key, Envelope envelope) =>
      SecureSession(key: key).openOrNull(envelope);

  void listen() {
    _sub = socket.listen(
      _onData,
      onError: (Object e) => _teardown('socket 错误: $e'),
      onDone: () => _teardown('对端关闭连接'),
      cancelOnError: true,
    );
  }

  void _onData(dynamic raw) {
    if (isClosed) return;
    if (raw is! String) {
      // 协议只用文本帧；二进制帧视为违规流量。
      _teardown('收到非文本帧');
      return;
    }

    // 1) 明文握手消息（`pair_request` / `pair_fail`）。
    //    必须先于信封解析判断：明文消息没有 payload/tag，若当信封解析会抛异常，
    //    服务端就会把「配对请求」误当成坏包直接断链。
    final plain = _tryDecodePlain(raw);
    if (plain != null) {
      _onPlain(plain);
      return;
    }

    // 2) 加密信封。
    Envelope envelope;
    try {
      envelope = Envelope.decode(raw);
    } catch (e) {
      // 协议异常：直接断开，不在畸形流量上浪费资源。
      _teardown('信封解析失败: $e');
      return;
    }

    // 握手阶段：交给上层按明文 type 路由。
    if (_phase == PeerPhase.handshake) {
      final handler = onHandshakeEnvelope;
      if (handler == null) {
        _teardown('握手阶段收到消息但无处理器');
        return;
      }
      unawaited(handler(this, envelope));
      return;
    }

    // 认证后：正常解密路径。
    final key = _key;
    final cache = _nonceCache;
    if (key == null || cache == null) {
      _teardown('未设置会话密钥');
      return;
    }

    Map<String, dynamic> body;
    try {
      body = SecureSession(key: key, nonceCache: cache).open(envelope);
    } on EnvelopeException catch (e) {
      // 安全要求：GCM 校验失败或重放 → 丢弃消息并断开连接。
      Log.error('消息被丢弃：${e.message}');
      _teardown('安全校验失败：${e.message}');
      return;
    }

    engine.onMessage(this, envelope.type, body);
  }

  void _onPlain(Map<String, dynamic> plain) {
    final type = plain['type'] as String;
    if (_phase == PeerPhase.handshake) {
      final handler = onHandshakePlain;
      if (handler == null) {
        _teardown('握手阶段收到明文消息但无处理器');
        return;
      }
      unawaited(_dispatchPlain(handler, type, plain));
      return;
    }
    // 认证后再出现握手明文 → 视为降级尝试，直接断开。
    if (_isHandshakePlainType(type)) {
      _teardown('认证后收到握手明文 $type');
      return;
    }
    Log.debug('认证后收到未知明文消息 $type，忽略');
  }

  /// 把一帧当作**明文**协议消息解析，不是明文则返回 null。
  ///
  /// 加密信封必然带 `payload` + `tag`；明文消息不带 —— 用这一点区分，
  /// 而不是靠 try/catch 猜（猜错会把握手消息当成坏信封直接断链）。
  static Map<String, dynamic>? _tryDecodePlain(String raw) {
    if (!raw.startsWith('{')) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final map = decoded.cast<String, dynamic>();
      if (map.containsKey('payload') || map.containsKey('tag')) return null;
      return map['type'] is String ? map : null;
    } catch (_) {
      return null;
    }
  }

  static bool _isHandshakePlainType(String type) =>
      type == MsgType.pairRequest || type == MsgType.pairFail;

  Future<void> _dispatchPlain(
    Future<bool> Function(PeerSession, String, Map<String, dynamic>) handler,
    String type,
    Map<String, dynamic> body,
  ) async {
    var handled = false;
    try {
      handled = await handler(this, type, body);
    } catch (e) {
      Log.error('处理握手明文失败 $type', e);
    }
    if (!handled && !isClosed) {
      Log.debug('握手阶段收到意外明文类型 $type，断开');
      _teardown('意外消息类型 $type');
    }
  }

  /// 认证后发送一条加密消息。
  void send(String type, Map<String, dynamic> body) {
    final key = _key;
    if (key == null || isClosed) return;
    final env = SecureSession(key: key).seal(type, body);
    try {
      socket.add(env.encode());
    } catch (e) {
      Log.error('发送失败 $type', e);
      _teardown('发送失败: $e');
    }
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = Timer.periodic(
      const Duration(seconds: ProtocolConst.heartbeatSeconds),
      (_) => send(MsgType.ping, <String, dynamic>{
        Field.ts: DateTime.now().toUtc().toIso8601String(),
      }),
    );
  }

  /// 主动关闭。
  Future<void> close([String reason = '']) async {
    if (isClosed) return;
    _phase = PeerPhase.closed;
    _heartbeat?.cancel();
    await _sub?.cancel();
    try {
      await socket.close(WebSocketStatus.normalClosure, reason);
    } catch (_) {
      // 关闭失败无需处理。
    }
    onClosed?.call(this);
  }

  void _teardown(String reason) {
    if (isClosed) return;
    Log.debug('连接结束（$remoteLabel）：$reason');
    _phase = PeerPhase.closed;
    _heartbeat?.cancel();
    unawaited(_sub?.cancel());
    try {
      socket.close();
    } catch (_) {
      // 已断开。
    }
    engine.onSessionClosed(this);
    onClosed?.call(this);
  }
}
