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
}
