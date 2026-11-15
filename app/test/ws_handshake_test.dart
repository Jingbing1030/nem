import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/db/database.dart';
import 'package:lan_notepad/src/db/note_repository.dart';
import 'package:lan_notepad/src/db/paths.dart';
import 'package:lan_notepad/src/images/image_vault.dart';
import 'package:lan_notepad/src/net/net_service.dart';
import 'package:lan_notepad/src/net/sync_engine.dart';
import 'package:notepad_core/notepad_core.dart';

/// **真实 WebSocket** 的握手集成测试。
///
/// ## 为什么必须用真实 socket
///
/// 核心包（`packages/notepad_core`）的端到端测试用的是**内存传输**，
/// 从不经过 HTTP Upgrade —— 因此「服务端从未完成 WebSocket 升级握手」
/// 这个 bug 能一路溜过 366 个测试，直到用户真机配对时才暴露：
///
/// > 连接后配对必定失败
///
/// 根因：服务端用裸 `ServerSocket.bind()` 收连接，然后直接
/// `WebSocket.fromUpgradedSocket(...)` —— 而该方法**假定升级握手已完成**
/// （Dart SDK 文档原文："The initial WebSocket handshake must have occurred
/// prior to this call"）。裸 socket 从没回过 `101 Switching Protocols`，
/// 客户端的 `WebSocket.connect` 于是永远等不到升级响应而超时。
///
/// 本文件用真实 `HttpServer` + `WebSocket.connect` 覆盖这条路径，
/// 保证「能被真正连上」这件事有测试守门。
void main() {
  late Directory tmpRoot;
  late NetService server;
  late AppDatabase serverDb;
  late List<Object> logErrors;

  /// 构造一个最小的、可用于握手的 NetService。
  Future<NetService> buildService({
    required String deviceId,
    required String deviceName,
    required String? masterKey,
  }) async {
    final dir = Directory.systemTemp.createTempSync('wstest-$deviceId');
    tmpRoot = dir;
    final paths = VaultPaths2.at(dir);
    await paths.ensureLayout();

    final db = AppDatabase.atFile(paths.dbFile);
    await db.enableForeignKeys();
    serverDb = db;

    final engine = SyncEngine(
      repo: NoteRepository2(db: db, paths: paths, deviceId: deviceId),
      paths: paths,
      imageVault: ImageVault(paths),
      onProgress: (_) {},
      onPeerAuthenticated: (_) {},
    );

    return NetService(
      deviceId: deviceId,
      deviceName: deviceName,
      getMasterKey: () async => masterKey,
      engine: engine,
    );
  }

  setUp(() {
    logErrors = <Object>[];
  });

  tearDown(() async {
    try {
      await server.stopServer();
    } catch (_) {
      // 已停止。
    }
    try {
      await serverDb.close();
    } catch (_) {
      // 已关闭。
    }
    if (tmpRoot.existsSync()) {
      try {
        tmpRoot.deleteSync(recursive: true);
      } catch (_) {
        // 测试临时目录，删不掉也无妨。
      }
    }
  });

  group('WebSocket 升级握手（真实 socket）', () {
    test('服务端能被 WebSocket.connect 真正连上（核心回归）', () async {
      server = await buildService(
        deviceId: 'dev-a',
        deviceName: '设备A',
        masterKey: Kdf.generateMasterKey(),
      );

      final port = await server.startServer();
      expect(port, greaterThan(0));

      // 这正是曾经失败的地方：裸 ServerSocket 从不回 101，这里会超时。
      final ws = await WebSocket.connect('ws://127.0.0.1:$port')
          .timeout(const Duration(seconds: 10));

      expect(ws.readyState, WebSocket.open);
      await ws.close();
    });

    test('普通 HTTP 请求得到 400，而不是悬挂连接', () async {
      server = await buildService(
        deviceId: 'dev-a',
        deviceName: '设备A',
        masterKey: Kdf.generateMasterKey(),
      );
      final port = await server.startServer();

      final client = HttpClient();
      final req = await client.get('127.0.0.1', port, '/');
      final resp = await req.close().timeout(const Duration(seconds: 10));

      expect(resp.statusCode, 400,
          reason: '非升级请求应被明确拒绝，避免调用方一直等');
      await resp.drain<void>();
      client.close();
    });

    test('服务端返回 101 且带上 Upgrade 头（验证真的是 WS 握手）', () async {
      server = await buildService(
        deviceId: 'dev-a',
        deviceName: '设备A',
        masterKey: Kdf.generateMasterKey(),
      );
      final port = await server.startServer();

      // 手工发一次升级请求，直接检查状态行与响应头。
      final socket = await Socket.connect('127.0.0.1', port);
      socket.write(
        'GET / HTTP/1.1\r\n'
        'Host: 127.0.0.1:$port\r\n'
        'Upgrade: websocket\r\n'
        'Connection: Upgrade\r\n'
        'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\n'
        '\r\n',
      );
      await socket.flush();

      final buf = StringBuffer();
      await socket
          .cast<List<int>>()
          .transform(const SystemEncoding().decoder)
          .listen(buf.write)
          .asFuture<void>()
          .timeout(const Duration(seconds: 5), onTimeout: () {});

      final head = buf.toString();
      expect(head, contains('101'),
          reason: '服务端必须回 101 Switching Protocols，否则客户端永远等不到升级');
      expect(head.toLowerCase(), contains('upgrade: websocket'));
      expect(head.toLowerCase(), contains('sec-websocket-accept'));

      await socket.close();
    });

    test('stopServer 后端口不再接受连接', () async {
      server = await buildService(
        deviceId: 'dev-a',
        deviceName: '设备A',
        masterKey: Kdf.generateMasterKey(),
      );
      final port = await server.startServer();
      await server.stopServer();

      await expectLater(
        WebSocket.connect('ws://127.0.0.1:$port')
            .timeout(const Duration(seconds: 5)),
        throwsA(anything),
      );
    });

    test('重复 startServer 返回同一端口（幂等）', () async {
      server = await buildService(
        deviceId: 'dev-a',
        deviceName: '设备A',
        masterKey: Kdf.generateMasterKey(),
      );
      final p1 = await server.startServer();
      final p2 = await server.startServer();
      expect(p2, p1);
    });
  });

  // ── 真实双端配对（用户实际做的事：A 显示码，B 输入码）──────────────
  //
  // 前面的用例只证明「能连上」。用户报的是「连接后配对**必定失败**」，
  // 所以这里要真的走完 `pair_request` → `pair_success` 全流程，
  // 并断言 B 最终拿到了 A 的 masterKey。
  group('真实双端配对全流程', () {
    test('B 用 A 显示的配对码配对成功，并拿到 A 的 masterKey', () async {
      final hostKey = Kdf.generateMasterKey();

      // A：主机（显示配对码）。
      server = await buildService(
        deviceId: 'dev-host',
        deviceName: '主机A',
        masterKey: hostKey,
      );
      final port = await server.startServer();

      // A 当前显示的 6 位配对码（与真机「本机配对码」页一致）。
      final code = PairingHandshake.currentCode(hostKey);
      expect(code, matches(RegExp(r'^[0-9]{6}$')));

      // B：加入方（无密钥），走真实 WS 连接。
      final joiner = await buildService(
        deviceId: 'dev-join',
        deviceName: '加入方B',
        masterKey: null,
      );
      // 用同一个 tmpRoot 会冲突，这里单独建一个：
      // buildService 内部已各自 createTempSync，故无需处理。

      String? received;
      joiner.onMasterKeyReceived = (mk) async => received = mk;

      final peer = await joiner.connect(
        host: '127.0.0.1',
        port: port,
        pairingCode: code,
      );

      // 等握手完成（pair_success 到达并回 auth_ok）。
      await _waitUntil(() => received != null, timeout: const Duration(seconds: 15));

      expect(received, hostKey,
          reason: 'B 必须拿到 A 的 masterKey —— 这正是用户配不成功的那一步');
      // 注：hasMasterKey 在 SyncService 上（NetService 只负责握手）。
      // 这里断言 NetService 侧的等价信号：连接已认证。
      expect(peer.isAuthenticated, isTrue,
          reason: '配对成功后应切到会话密钥并进入 ready 阶段');

      await peer.close();
      await joiner.stopServer();
    });

    test('配对码错误 → 得到 pair_fail，且不会拿到密钥', () async {
      final hostKey = Kdf.generateMasterKey();
      server = await buildService(
        deviceId: 'dev-host',
        deviceName: '主机A',
        masterKey: hostKey,
      );
      final port = await server.startServer();

      final real = PairingHandshake.currentCode(hostKey);
      // 构造一个必然不同的 6 位码。
      final wrong = real == '000000' ? '111111' : '000000';

      final joiner = await buildService(
        deviceId: 'dev-join',
        deviceName: '加入方B',
        masterKey: null,
      );
      String? received;
      joiner.onMasterKeyReceived = (mk) async => received = mk;

      final peer = await joiner.connect(
        host: '127.0.0.1',
        port: port,
        pairingCode: wrong,
      );

      // 等服务端拒绝并关闭连接。
      await _waitUntil(() => peer.isClosed, timeout: const Duration(seconds: 15));

      expect(received, isNull, reason: '错误配对码绝不能拿到密钥');
      expect(peer.isClosed, isTrue, reason: '按协议失败后必须立即关闭连接');

      await joiner.stopServer();
    });
  });
}

/// 轮询等待条件成立（避免用固定 sleep 造成测试不稳）。
Future<void> _waitUntil(
  bool Function() cond, {
  required Duration timeout,
  Duration step = const Duration(milliseconds: 50),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (cond()) return;
    await Future<void>.delayed(step);
  }
  throw TimeoutException('等待条件超时（$timeout）');
}
