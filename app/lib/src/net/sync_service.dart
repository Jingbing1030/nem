import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:notepad_core/notepad_core.dart';

import '../config/config_store.dart';
import '../db/note_repository.dart';
import '../db/paths.dart';
import '../images/image_vault.dart';
import '../log.dart';
import 'mdns_service.dart';
import 'net_service.dart';
import 'sync_engine.dart';

/// 把「网络 + 发现 + 同步」三块编排在一起，并暴露给 UI。
///
/// 生命周期（需求 5.6）：应用回前台启动广播/监听，进后台停止。
class SyncService extends ChangeNotifier {
  SyncService({
    required this.configStore,
    required this.repo,
    required this.paths,
    required this.imageVault,
    required this.deviceId,
    required this.deviceName,
  }) {
    _engine = SyncEngine(
      repo: repo,
      paths: paths,
      imageVault: imageVault,
      onProgress: (pr) {
        progress = pr;
        notifyListeners();
      },
      onPeerAuthenticated: (_) {
        statusText = '已连接';
        notifyListeners();
      },
    );

    _net = NetService(
      deviceId: deviceId,
      deviceName: deviceName,
      getMasterKey: configStore.readMasterKey,
      engine: _engine,
    )..onMasterKeyReceived = (mk) async {
        // 首次配对成功：把 masterKey 落到 secure_storage。
        await configStore.writeMasterKey(mk);
        await ensureMdns(force: true);
        notifyListeners();
      };

    _net.stateStream.listen((s) {
      netState = s;
      notifyListeners();
    });

    _engine.progressStream.listen((pr) {
      progress = pr;
      notifyListeners();
    });
  }

  final ConfigStore configStore;
  final NoteRepository2 repo;
  final VaultPaths2 paths;
  final ImageVault imageVault;
  final String deviceId;
  final String deviceName;

  late final SyncEngine _engine;
  late final NetService _net;
  MdnsService? _mdns;
  StreamSubscription<List<DiscoveredPeer>>? _peerSub;

  /// 发现到的设备列表。
  List<DiscoveredPeer> peers = <DiscoveredPeer>[];

  NetState netState = NetState.stopped;
  SyncProgress progress = const SyncProgress();

  /// 当前设备是否已持有 masterKey（决定 UI 文案）。
  bool hasMasterKey = false;

  String statusText = '未连接';

  /// 本机 WS 端口（0 表示未启动）。
  int get port => _net.port;

  /// 是否正在广播。
  bool get isAdvertising => _mdns?.advertisedPort != 0;

  /// 当前应显示的配对码（未持有 masterKey 时返回 null）。
  Future<String?> currentPairingCode() async {
    final mk = await configStore.readMasterKey();
    return mk == null ? null : PairingHandshake.currentCode(mk);
  }

  /// 启动：开服务端 → 广播 → 监听。
  Future<void> start() async {
    hasMasterKey = await configStore.hasMasterKey();
    final port = await _net.startServer();
    await _startMdns(port);
    notifyListeners();
  }

  Future<void> _startMdns(int wsPort) async {
    // 注意：hasKey / deviceName 会随配对与改名而变化，而 MdnsService 的这两个值
    // 是构造期固定的，写入的是 TXT 记录。因此**每次都要重建**，否则广播内容会过期
    // （典型症状：配对成功后，对端仍看到 hasKey=0）。
    await _mdns?.dispose();
    _mdns = MdnsService(
      deviceId: deviceId,
      deviceName: deviceName,
      hasKey: hasMasterKey,
    );
    await _mdns!.start(wsPort: wsPort);
    await _peerSub?.cancel();
    _peerSub = _mdns!.peersStream.listen((list) {
      peers = list;
      notifyListeners();
    });
  }

  /// 重新广播（设备名 / hasKey / 端口变化时）。
  ///
  /// 重建 MdnsService 以刷新 TXT 记录，而不是复用旧实例。
  Future<void> ensureMdns({bool force = false}) async {
    hasMasterKey = await configStore.hasMasterKey();
    if (force) {
      await _startMdns(_net.port);
    }
  }

  /// 停止广播与监听（进入后台）。
  Future<void> stop() async {
    await _mdns?.stop();
    await _net.stopServer();
    peers = <DiscoveredPeer>[];
    netState = NetState.stopped;
    notifyListeners();
  }

  /// 连接某台设备（[pairingCode] 为空表示已配对重连）。
  Future<void> connectTo(DiscoveredPeer peer, {String? pairingCode}) async {
    statusText = pairingCode == null ? '正在重连…' : '正在配对…';
    notifyListeners();
    try {
      await _net.connect(
        host: peer.host,
        port: peer.port,
        pairingCode: pairingCode,
      );
    } catch (e) {
      statusText = '连接失败：$e';
      Log.error('连接失败', e);
      notifyListeners();
      rethrow;
    }
  }

  /// 生成/重置 masterKey。
  ///
  /// 重置后所有已配对设备都需要重新配对（需求 5.5）。
  Future<void> resetMasterKey() async {
    final mk = Kdf.generateMasterKey();
    await configStore.writeMasterKey(mk);
    hasMasterKey = true;
    await _net.stopServer();
    final port = await _net.startServer();
    await _mdns?.restart(wsPort: port);
    statusText = '密钥已重置，请在所有设备上重新配对';
    progress = const SyncProgress();
    notifyListeners();
  }

  /// 首次生成 masterKey（若尚无）。
  Future<void> ensureMasterKey() async {
    if (await configStore.hasMasterKey()) {
      hasMasterKey = true;
      return;
    }
    await configStore.writeMasterKey(Kdf.generateMasterKey());
    hasMasterKey = true;
    await _mdns?.restart(wsPort: _net.port);
    notifyListeners();
  }

  /// 本地笔记变更后触发增量同步（500ms 防抖由调用方负责）。
  Future<void> notifyLocalChange() async {
    for (final s in _net.sessions) {
      if (s.isAuthenticated) {
        await _engine.notifyLocalChange(s);
      }
    }
  }

  /// 手动触发全量对比。
  Future<void> syncNow() async {
    for (final s in _net.sessions) {
      if (s.isAuthenticated) {
        await _engine.startSync(s);
      }
    }
  }

  @override
  void dispose() {
    _peerSub?.cancel();
    _mdns?.dispose();
    _net.dispose();
    _engine.dispose();
    super.dispose();
  }
}

/// 同步服务的 Provider（在 main() 里 override）。
final syncServiceProvider = Provider<SyncService>(
  (ref) => throw StateError('syncServiceProvider 必须在 main() 中 override'),
);

/// 设备列表（由 SyncService 推送）。
final peersProvider = Provider<List<DiscoveredPeer>>(
  (ref) => ref.watch(syncServiceProvider).peers,
);
