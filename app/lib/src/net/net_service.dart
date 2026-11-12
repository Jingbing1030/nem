import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:notepad_core/notepad_core.dart';

import '../log.dart';
import 'pairing_guard.dart';
import 'peer_session.dart';
import 'sync_engine.dart';

/// 连接状态。
enum NetState { stopped, listening, connected }

/// WS 网络服务：既是服务端（监听 + 广播）也是客户端（连接对端）。
///
/// 握手两条路径（需求 5.5 / 变更 5）：
/// - 首次配对：`pair_request`（**明文** + HMAC 证明）→ 校验 TOTP（±1 窗口）
///   → `pair_success`(masterKey，用命中码派生的密钥加密) / `pair_fail`(明文)
/// - 已配对重连：`fast_auth` → 能解密即认证 → `auth_ok`
///
/// **实现要点**：信封的 `type` 是明文，因此服务端**无需先解密**就能区分这两条路径，
/// 这在密码学上解决了「配对码既是密钥又在载荷里」的循环依赖。
/// 变更 5 之后 `pair_request` 改为明文 + HMAC，其 nonce 由 [NonceCache] 做重放拒绝。
class NetService {
  NetService({
    required this.deviceId,
    required this.deviceName,
    required this.getMasterKey,
    required this.engine,
  });

  final String deviceId;
  final String deviceName;

  /// 读取 masterKey（**唯一来源是 secure_storage**）。
  final Future<String?> Function() getMasterKey;

  final SyncEngine engine;

  ServerSocket? _server;
  final List<PeerSession> _sessions = <PeerSession>[];
  final PairingGuard _guard = PairingGuard();

  /// fast_auth 信封的重放防护（按 nonce 去重，60s 过期）。
  ///
  /// 握手阶段用的是「一次性的 SecureSession」，每次解密都新建实例，
  /// 因此 Session 内部的 NonceCache 起不到跨请求的去重作用 ——
  /// 重放同一个 fast_auth 信封仍会「解密成功 → 认证通过」。
  /// 虽然 fast_auth 是无状态认证、危害有限（最多多一次重连），
  /// 但验收清单要求「重放旧消息被 nonce 缓存拒绝」，故在此显式加固。
  final TtlNonceCache _fastAuthNonces = TtlNonceCache(
    ttl: Duration(seconds: ProtocolConst.pairNonceTtlSeconds),
  );

  /// `pair_request` 的 nonce 重放缓存（需求 5.5：同一 nonce 只接受一次）。
  final NonceCache _pairNonces = NonceCache(
    capacity: ProtocolConst.nonceCacheSize,
  );

  final StreamController<NetState> _stateCtrl =
      StreamController<NetState>.broadcast();

  NetState _state = NetState.stopped;
  NetState get state => _state;
  Stream<NetState> get stateStream => _stateCtrl.stream;

  /// 实际监听到的端口（动态分配）。
  int get port => _server?.port ?? 0;

  List<PeerSession> get sessions =>
      _sessions.where((s) => !s.isClosed).toList();

  bool get hasActiveSession => sessions.any((s) => s.isAuthenticated);

  void _setState(NetState s) {
    _state = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  // ------------------------------------------------------------ 服务端

  /// 启动服务端，端口动态分配（需求 5.6：避免固定端口冲突）。
  Future<int> startServer() async {
    if (_server != null) return port;
    final server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _server = server;
    _setState(NetState.listening);
    server.listen(_onSocket, onError: (Object e) {
      Log.error('服务端 socket 错误', e);
    });
    Log.debug('WS 服务端监听 0.0.0.0:${server.port}');
    return server.port;
  }

  Future<void> stopServer() async {
    for (final s in sessions) {
      await s.close('服务端关闭');
    }
    _sessions.clear();
    await _server?.close();
    _server = null;
    _setState(NetState.stopped);
  }

  void _onSocket(Socket socket) {
    final ip = PairingGuard.ipOf(socket);
    Log.debug('收到来自 $ip 的连接');

    final ws = WebSocket.fromUpgradedSocket(socket, serverSide: true);
    final peer = PeerSession(
      socket: ws,
      remoteLabel: ip,
      engine: engine,
      onHandshakeEnvelope: _onServerHandshake,
      onHandshakePlain: _onServerPlain,
      onClosed: _removeSession,
    );
    _sessions.add(peer);
    peer.listen();
  }

  /// 服务端握手：**明文**握手消息（`pair_request`）。
  Future<bool> _onServerPlain(
    PeerSession peer,
    String type,
    Map<String, dynamic> body,
  ) async {
    if (type != MsgType.pairRequest) return false;
    await handlePairRequest(peer, peer.remoteLabel, body);
    return true;
  }

  /// 服务端握手：**加密**信封（已配对设备走 `fast_auth`）。
  Future<void> _onServerHandshake(PeerSession peer, Envelope envelope) async {
    if (envelope.type == MsgType.fastAuth) {
      await handleFastAuth(peer, envelope);
      return;
    }
    Log.debug('握手阶段收到意外类型 ${envelope.type}，断开');
    await peer.close('意外消息类型');
  }

  /// 处理配对请求（服务端侧，明文 + HMAC 证明）。
  Future<void> handlePairRequest(
    PeerSession peer,
    String ip,
    Map<String, dynamic> body,
  ) async {
    // 限流：同一 IP 60s 内失败 3 次 → 锁 60s。
    if (_guard.isLocked(ip)) {
      final remaining = _guard.lockRemainingSeconds(ip);
      Log.debug('配对锁定中（$ip，剩余 ${remaining}s）');
      await _fail(peer, ip, '失败次数过多，请 $remaining 秒后重试', countFailure: false);
      return;
    }

    final masterKey = await getMasterKey();
    if (masterKey == null) {
      await _fail(peer, ip, '本机尚未生成密钥，请在本机发起配对', countFailure: false);
      return;
    }

    final request = PairRequest.fromJson(body);
    if (request == null) {
      // 载荷格式错误：不计入失败次数（否则可被廉价伪造用来锁死正常设备）。
      await _fail(peer, ip, '配对请求格式错误', countFailure: false);
      return;
    }

    final attempt = PairingHandshake.verifyRequest(
      request: request,
      masterKey: masterKey,
      nowMillis: DateTime.now().millisecondsSinceEpoch,
      nonceCache: _pairNonces,
    );

    if (attempt.status == PairingHandshake.ok) {
      final key = attempt.key!;
      peer.remoteDeviceId = request.deviceId;
      peer.remoteDeviceName = request.deviceName;
      _guard.recordSuccess(ip);

      // 用握手密钥把 masterKey 回传，随后双方切到会话密钥。
      peer.sendHandshake(
        PairingHandshake.buildSuccess(
          handshakeKey: key,
          masterKey: masterKey,
        ),
      );
      Log.debug('配对成功：${peer.remoteDeviceName}（$ip）');
      peer.activate(Kdf.sessionKey(masterKey));
      _setState(NetState.connected);
      await engine.startSync(peer);
      return;
    }

    switch (attempt.status) {
      case PairingHandshake.badTime:
        await _fail(peer, ip, '设备时间偏差过大，请校准时间后重试');
      case PairingHandshake.replayed:
        // 重放不计入失败次数：否则攻击者重放旧包即可锁死正常设备。
        await _fail(peer, ip, '重复的配对请求', countFailure: false);
      default:
        await _fail(peer, ip, '配对码错误');
    }
  }

  /// 回 `pair_fail`（明文）并关闭连接（需求：失败后立即关闭）。
  Future<void> _fail(
    PeerSession peer,
    String ip,
    String reason, {
    bool countFailure = true,
  }) async {
    if (countFailure) {
      _guard.recordFailure(ip);
      Log.debug('配对失败（$ip，第 ${_guard.failureCount(ip)} 次）：$reason');
    }
    // `pair_fail` 按协议是明文 `{type, reason}`：对端此刻可能还没拿到 masterKey，
    // 无法派生会话密钥，因此不能用加密信封回（会被对端判为解密失败）。
    peer.sendPlain(PairingHandshake.buildFailure(reason));
    await peer.close('pair_fail: $reason');
  }

  /// 处理 fast_auth（已配对设备重连）。
  ///
  /// **「能解密成功」本身即认证**：只有持有相同 masterKey 的设备
  /// 才能派生出相同会话密钥，GCM 标签提供了密码学保证。
  Future<void> handleFastAuth(PeerSession peer, Envelope envelope) async {
    final masterKey = await getMasterKey();
    if (masterKey == null) {
      await peer.close('本机无密钥');
      return;
    }

    // 重放拒绝：同一信封只接受一次（按 nonce 去重）。
    if (!_fastAuthNonces.checkAndStore(envelope.payload.nonce)) {
      Log.debug('fast_auth 重放，拒绝：${peer.remoteLabel}');
      await peer.close('重复的认证请求');
      return;
    }

    final sessionKey = Kdf.sessionKey(masterKey);
    final body = peer.openHandshake(sessionKey, envelope);
    if (body == null) {
      // 解密失败 → 不是已配对设备（或密钥已被重置）→ 断开，提示重新配对。
      Log.debug('fast_auth 解密失败，断开：${peer.remoteLabel}');
      await peer.close('fast_auth 失败，请重新配对');
      return;
    }

    peer.remoteDeviceId = body[Field.deviceId] as String?;
    peer.activate(sessionKey);
    peer.send(MsgType.authOk, <String, dynamic>{
      Field.serverDeviceId: deviceId,
    });
    Log.debug('fast_auth 通过：${peer.remoteDeviceId}');
    _setState(NetState.connected);
    await engine.startSync(peer);
  }

  // ------------------------------------------------------------ 客户端

  /// 主动连接对端。
  ///
  /// [pairingCode] 非空 → 走首次配对；为空 → 走已配对重连（fast_auth）。
  Future<PeerSession> connect({
    required String host,
    required int port,
    String? pairingCode,
  }) async {
    final socket = await WebSocket.connect('ws://$host:$port');
    // 首次配对时用它解 `pair_success`（与 `pair_request` 的 HMAC 同源：PBKDF2(code)）。
    final Uint8List? handshakeKey =
        pairingCode == null ? null : Kdf.pairKey(pairingCode);

    final peer = PeerSession(
      socket: socket,
      remoteLabel: '$host:$port',
      engine: engine,
      onHandshakeEnvelope: (p, env) => _onClientHandshake(p, env, handshakeKey),
      onHandshakePlain: (p, type, body) =>
          _onClientPlain(p, type, body, handshakeKey),
      onClosed: _removeSession,
    );
    _sessions.add(peer);
    peer.listen();

    if (pairingCode != null) {
      // 首次配对：`pair_request` 明文发送，配对码只用来算 HMAC，不作为明文字段传输。
      final request = PairingHandshake.buildRequest(
        code: pairingCode,
        deviceId: deviceId,
        deviceName: deviceName,
        clientTime: DateTime.now().millisecondsSinceEpoch,
      );
      peer.sendPlain(request.toJson());
    } else {
      final mk = await getMasterKey();
      if (mk == null) {
        throw StateError('本机没有 masterKey，无法免配对重连；请先配对');
      }
      final sessionKey = Kdf.sessionKey(mk);
      peer.sendHandshake(
        SecureSession(key: sessionKey)
            .seal(MsgType.fastAuth, <String, dynamic>{Field.deviceId: deviceId}),
      );
      // 等 auth_ok 到达后 activate。
    }
    return peer;
  }

  /// 客户端握手：**明文**消息（`pair_fail`）。
  Future<bool> _onClientPlain(
    PeerSession peer,
    String type,
    Map<String, dynamic> body,
    Uint8List? handshakeKey,
  ) async {
    if (type != MsgType.pairFail) return false;
    final reason = body[Field.reason] as String?;
    Log.debug('配对失败：${reason ?? '未知原因'}');
    await peer.close(reason ?? '配对失败');
    return true;
  }

  /// 客户端握手：**加密**信封（等 `pair_success` / `auth_ok`）。
  Future<void> _onClientHandshake(
    PeerSession peer,
    Envelope envelope,
    Uint8List? handshakeKey,
  ) async {
    switch (envelope.type) {
      case MsgType.pairSuccess:
        if (handshakeKey == null) {
          await peer.close('未预期的 pair_success');
          return;
        }
        final masterKey = PairingHandshake.openSuccess(
          handshakeKey: handshakeKey,
          envelope: envelope,
        );
        if (masterKey == null) {
          await peer.close('pair_success 解密失败');
          return;
        }
        // 配对成功：上层负责把 masterKey 落到 secure_storage。
        await onMasterKeyReceived?.call(masterKey);
        peer.activate(Kdf.sessionKey(masterKey));
        _setState(NetState.connected);
        await engine.startSync(peer);

      case MsgType.authOk:
        final mk = await getMasterKey();
        if (mk == null) {
          await peer.close('缺少 masterKey');
          return;
        }
        peer.remoteDeviceId = null;
        peer.activate(Kdf.sessionKey(mk));
        _setState(NetState.connected);
        await engine.startSync(peer);

      default:
        Log.debug('客户端握手阶段收到意外类型 ${envelope.type}');
    }
  }

  /// 客户端收到 masterKey 时的回调（由上层写入 secure_storage）。
  Future<void> Function(String masterKey)? onMasterKeyReceived;

  void _removeSession(PeerSession peer) {
    _sessions.remove(peer);
    if (!hasActiveSession) {
      _setState(_server != null ? NetState.listening : NetState.stopped);
    }
  }

  Future<void> dispose() async {
    await stopServer();
    await _stateCtrl.close();
  }
}
