import 'dart:async';
import 'dart:io';

import 'package:mdns_dart/mdns_dart.dart' as mdns;

import '../log.dart';

/// 局域网里发现到的一台设备。
class DiscoveredPeer {
  const DiscoveredPeer({
    required this.deviceId,
    required this.deviceName,
    required this.host,
    required this.port,
    required this.hasKey,
  });

  final String deviceId;
  final String deviceName;
  final String host;
  final int port;

  /// 对端是否已持有 masterKey（TXT `hasKey`）。
  final bool hasKey;

  @override
  String toString() =>
      'DiscoveredPeer($deviceName/$deviceId @$host:$port hasKey=$hasKey)';
}

/// mDNS 服务：既广播自己，也监听别人。
///
/// 需求 5.6：
/// - 服务端注册 `_notepad._tcp.local`，动态端口写入 TXT
/// - 客户端订阅该服务类型，实时更新设备列表
/// - 应用回前台才广播/监听，进后台停止（移动端）
///
/// 广播用 [mdns.MDNSService] + [mdns.MDNSServer]，
/// 发现用 [mdns.MDNSClient.lookup]，两者都来自 `mdns_dart`。
class MdnsService {
  MdnsService({
    required this.deviceId,
    required this.deviceName,
    required this.hasKey,
  });

  /// 本机设备 UUID。
  final String deviceId;

  /// 本机设备名。
  final String deviceName;

  /// 本机是否已持有 masterKey。
  final bool hasKey;

  /// 服务类型。mdns_dart 要求**不带**结尾点（它会自行归一化）。
  static const String serviceType = '_notepad._tcp';

  final StreamController<List<DiscoveredPeer>> _peersController =
      StreamController<List<DiscoveredPeer>>.broadcast();

  final Map<String, DiscoveredPeer> _peers = <String, DiscoveredPeer>{};
  final Map<String, DateTime> _lastSeen = <String, DateTime>{};

  mdns.MDNSServer? _server;
  StreamSubscription<mdns.ServiceEntry>? _sub;
  Timer? _ttlTimer;
  int _advertisedPort = 0;

  /// 多久没再出现就从列表移除（对端关闭广播后的兜底）。
  static const Duration _peerTtl = Duration(seconds: 45);

  /// 设备列表更新流。
  Stream<List<DiscoveredPeer>> get peersStream => _peersController.stream;

  /// 当前设备列表快照。
  List<DiscoveredPeer> get peers {
    final list = _peers.values.toList();
    list.sort((a, b) => a.deviceName.compareTo(b.deviceName));
    return list;
  }

  /// 正在广播的端口（未广播时为 0）。
  int get advertisedPort => _advertisedPort;

  /// 选出本机用于广播的 IPv4 地址。
  Future<List<InternetAddress>> _localAddresses() async {
    final out = <InternetAddress>[];
    try {
      for (final iface in await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      )) {
        out.addAll(iface.addresses);
      }
    } catch (e) {
      Log.error('枚举网卡失败', e);
    }
    return out;
  }

  /// 开始广播自己 + 监听局域网。
  ///
  /// [wsPort] 是实际监听到的 WS 端口（动态分配后传入）。
  Future<void> start({required int wsPort}) async {
    if (_server != null) return;
    try {
      final ips = await _localAddresses();
      if (ips.isEmpty) {
        Log.debug('没有可用 IPv4 网卡，跳过 mDNS 广播');
        return;
      }

      final service = await mdns.MDNSService.create(
        instance: '$deviceName ($deviceId)',
        service: serviceType,
        port: wsPort,
        ips: ips,
        txt: <String>[
          'deviceName=$deviceName',
          'deviceId=$deviceId',
          'port=$wsPort',
          'hasKey=${hasKey ? '1' : '0'}',
        ],
      );

      _server = mdns.MDNSServer(mdns.MDNSServerConfig(zone: service));
      await _server!.start();
      _advertisedPort = wsPort;
      Log.debug('mDNS 已广播 $serviceType @$wsPort (hasKey=${hasKey ? 1 : 0})');

      await _startDiscovery();
    } catch (e) {
      // mDNS 不可用不应让应用起不来（某些机型/权限受限）。
      Log.error('mDNS 启动失败', e);
    }
  }

  Future<void> _startDiscovery() async {
    await _sub?.cancel();
    try {
      final stream = await mdns.MDNSClient.lookup(serviceType);
      _sub = stream.listen(
        _onEntry,
        onError: (Object e) => Log.error('mDNS 查询出错', e),
        cancelOnError: false,
      );
    } catch (e) {
      Log.error('mDNS 查询启动失败', e);
    }

    // 定时清理过期条目
    _ttlTimer ??= Timer.periodic(const Duration(seconds: 15), (_) {
      final now = DateTime.now();
      final before = _peers.length;
      _lastSeen.removeWhere((k, t) {
        if (now.difference(t) > _peerTtl) {
          _peers.remove(k);
          return true;
        }
        return false;
      });
      if (_peers.length != before) _emit();
    });
  }

  void _onEntry(mdns.ServiceEntry entry) {
    try {
      final txt = _parseTxt(entry.infoFields);
      final id = txt['deviceId'] ?? entry.name;

      // 忽略自己
      if (id == deviceId) return;

      final v4 = entry.addrsV4;
      final host = entry.addrV4?.address ??
          (v4 != null && v4.isNotEmpty ? v4.first.address : null);
      if (host == null || host.isEmpty) return;

      final txtPort = int.tryParse(txt['port'] ?? '') ?? 0;
      final port = txtPort != 0 ? txtPort : entry.port;
      if (port == 0) return;

      _peers[id] = DiscoveredPeer(
        deviceId: id,
        deviceName: txt['deviceName'] ?? _nameFromInstance(entry.name),
        host: host,
        port: port,
        hasKey: txt['hasKey'] == '1',
      );
      _lastSeen[id] = DateTime.now();
      _emit();
    } catch (e) {
      Log.error('解析 mDNS 条目失败', e);
    }
  }

  /// mdns_dart 的 instance 名形如 "设备名 (uuid)"，从中取出设备名。
  String _nameFromInstance(String instance) {
    final i = instance.lastIndexOf(' (');
    return i > 0 ? instance.substring(0, i) : instance;
  }

  Map<String, String> _parseTxt(List<String> fields) {
    final out = <String, String>{};
    for (final f in fields) {
      final i = f.indexOf('=');
      if (i > 0) out[f.substring(0, i)] = f.substring(i + 1);
    }
    return out;
  }

  /// 停止广播与监听（应用进入后台时调用）。
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _ttlTimer?.cancel();
    _ttlTimer = null;
    try {
      await _server?.stop();
    } catch (e) {
      Log.error('停止 mDNS 广播失败', e);
    }
    _server = null;
    _advertisedPort = 0;
    _peers.clear();
    _lastSeen.clear();
    _emit();
  }

  /// 重启（回到前台时调用，用于刷新 TXT 内容，如 hasKey / 端口变化）。
  Future<void> restart({required int wsPort}) async {
    await stop();
    await start(wsPort: wsPort);
  }

  void _emit() {
    if (_peersController.isClosed) return;
    _peersController.add(peers);
  }

  Future<void> dispose() async {
    await stop();
    await _peersController.close();
  }
}
