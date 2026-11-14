import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/mdns_service.dart';
import '../net/net_service.dart';
import '../net/pairing_actions.dart';
import '../net/sync_service.dart';
import '../theme/background_scaffold.dart';

/// 设备列表页：mDNS 发现的局域网设备 + 连接状态。
class DevicesPage extends ConsumerStatefulWidget {
  const DevicesPage({super.key});

  @override
  ConsumerState<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends ConsumerState<DevicesPage> {
  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(syncServiceProvider);
    final peers = ref.watch(peersProvider);
    final scheme = Theme.of(context).colorScheme;

    return BackgroundScaffold(
      appBar: AppBar(
        title: const Text('设备'),
        actions: <Widget>[
          IconButton(
            tooltip: '立即同步',
            icon: const Icon(Icons.sync),
            onPressed: () async {
              await svc.syncNow();
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(svc.progress.running ? '同步中…' : '已触发同步')),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: <Widget>[
          _StatusCard(svc: svc),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
            child: Row(
              children: <Widget>[
                Text(
                  '局域网设备',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  '${peers.length} 台',
                  style: TextStyle(fontSize: 12, color: scheme.outline),
                ),
              ],
            ),
          ),
          if (peers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: <Widget>[
                  Icon(Icons.wifi_find_outlined, size: 44, color: scheme.outline),
                  const SizedBox(height: 10),
                  const Text('未发现设备'),
                  const SizedBox(height: 6),
                  Text(
                    '请确认：两台设备在同一局域网、\n'
                    '对端应用处于前台、且路由器未开启「AP 隔离」。',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: scheme.outline, height: 1.6),
                  ),
                ],
              ),
            )
          else
            ...peers.map((peer) => _PeerTile(
                  peer: peer,
                  svc: svc,
                  onConnect: () => _connectFlow(context, peer, svc),
                )),
        ],
      ),
    );
  }

  /// 连接流程。
  ///
  /// ## 为什么不能只看 `hasMasterKey` 就决定走哪条路
  ///
  /// 早先的实现是：
  /// ```dart
  /// if (svc.hasMasterKey) { await svc.connectTo(peer); return; }  // 直接重连
  /// // 只有没有密钥时才弹输入框
  /// ```
  /// 而 `main()` **首次启动就无条件生成 masterKey**，于是 `hasMasterKey`
  /// 恒为 true —— **那个输入配对码的对话框永远不可达**，用户找不到任何
  /// 输入配对码的地方，两台设备各用各的密钥握手，必然失败。
  ///
  /// 「本机有密钥」只意味着**本机可以当主机**，不意味着**本机不能加入别人**。
  /// 因此这里改为：有密钥时让用户明确选择「重连」还是「输入对方配对码」。
  Future<void> _connectFlow(
    BuildContext context,
    DiscoveredPeer peer,
    SyncService svc,
  ) async {
    String? code;

    // 决策规则抽到 pairing_actions.dart 里并有单测覆盖 ——
    // 保证「输入配对码」这条路**永远存在**（这正是此前的 bug）。
    final actions = connectActionsFor(hasMasterKey: svc.hasMasterKey);

    if (actions.length > 1) {
      // 本机已有密钥：两条路都给（重连 / 输入对方码）。
      final action = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          title: Text('连接到 ${peer.deviceName}'),
          children: <Widget>[
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.of(ctx).pop(ConnectAction.reconnect.name),
              child: const ListTile(
                leading: Icon(Icons.link),
                title: Text('重新连接'),
                subtitle: Text('两台设备已配对过，直接建立连接'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.of(ctx).pop(ConnectAction.pairWithCode.name),
              child: const ListTile(
                leading: Icon(Icons.vpn_key),
                title: Text('输入对方的配对码'),
                subtitle: Text('首次与此设备配对，或改用对方的密钥'),
                contentPadding: EdgeInsets.zero,
              ),
            ),
          ],
        ),
      );
      if (action == null || !context.mounted) return;

      if (action == ConnectAction.reconnect.name) {
        try {
          await svc.connectTo(peer);
        } catch (e) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('重连失败：$e')),
          );
        }
        return;
      }

      // 选择「输入配对码」：先输入，再确认密钥会被替换。
      code = await _askCode(context, peer);
      if (code == null || !context.mounted) return;

      // 本机已有密钥 → 配对成功后本机密钥会被**对端的**密钥替换，
      // 与其它设备的既有配对随之失效（笔记数据本身不受影响，
      // 因为 masterKey 只用于传输加密）。这必须让用户明确确认。
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('替换本机密钥？'),
          content: const Text(
            '本机已有密钥。加入对方后，本机将改用对方的密钥，'
            '与其它设备的既有配对会失效（需要重新配对）。\n\n'
            '笔记数据本身不会丢失。',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('继续配对'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) return;
    } else {
      // 本机没有密钥：唯一可用的动作就是输入对端的码。
      // 用断言把「规则函数与 UI 分支一致」固化下来，避免将来又改歪。
      assert(
        actions.length == 1 && actions.first == ConnectAction.pairWithCode,
        '无密钥时必须且只能走「输入配对码」',
      );
      code = await _askCode(context, peer);
      if (code == null || !context.mounted) return;
    }

    try {
      await svc.connectTo(peer, pairingCode: code);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配对中…成功后会自动开始同步')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('配对失败：$e')),
      );
    }
  }

  /// 弹出 6 位配对码输入框。
  Future<String?> _askCode(BuildContext context, DiscoveredPeer peer) =>
      showDialog<String>(
        context: context,
        builder: (ctx) => _CodeInputDialog(peerName: peer.deviceName),
      );
}


/// 6 位配对码输入框。
class _CodeInputDialog extends StatefulWidget {
  const _CodeInputDialog({this.peerName});

  /// 目标设备名（仅用于提示文案）。
  final String? peerName;

  @override
  State<_CodeInputDialog> createState() => _CodeInputDialogState();
}

class _CodeInputDialogState extends State<_CodeInputDialog> {
  final TextEditingController _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('输入配对码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              widget.peerName == null
                  ? '请输入对端设备上显示的 6 位数字'
                  : '请输入「${widget.peerName}」上显示的 6 位数字',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _c,
              autofocus: true,
              keyboardType: TextInputType.number,
              maxLength: 6,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 26,
                fontFamily: 'monospace',
                letterSpacing: 6,
              ),
              decoration: const InputDecoration(
                counterText: '',
                hintText: '000000',
              ),
              onChanged: (v) {
                // 只接受数字；满 6 位自动提交，少一次点击。
                final digits = v.replaceAll(RegExp(r'\D'), '');
                if (digits != v) {
                  _c.value = TextEditingValue(
                    text: digits,
                    selection: TextSelection.collapsed(offset: digits.length),
                  );
                }
                if (digits.length == 6) Navigator.of(context).pop(digits);
              },
            ),
            const SizedBox(height: 6),
            Text(
              '配对码在对方的「配对」页显示，每 30 秒自动更换。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final v = _c.text.replaceAll(RegExp(r'\D'), '');
              if (v.length == 6) Navigator.of(context).pop(v);
            },
            child: const Text('连接'),
          ),
        ],
      );
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.svc});

  final SyncService svc;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final p = svc.progress;
    final stateText = switch (svc.netState) {
      NetState.stopped => '未启动',
      NetState.listening => '已启动，可被发现',
      NetState.connected => '已连接',
    };

    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  svc.netState == NetState.connected
                      ? Icons.link
                      : Icons.wifi_tethering,
                  color: svc.netState == NetState.connected
                      ? scheme.primary
                      : scheme.outline,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(stateText,
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      Text(
                        svc.statusText,
                        style: TextStyle(fontSize: 12, color: scheme.outline),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (p.running) ...<Widget>[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: p.notesTotal + p.imagesTotal == 0
                    ? null
                    : (p.notesDone + p.imagesDone) /
                        (p.notesTotal + p.imagesTotal),
              ),
              const SizedBox(height: 6),
              Text(
                '笔记 ${p.notesDone}/${p.notesTotal}'
                '${p.imagesTotal > 0 ? '　图片 ${p.imagesDone}/${p.imagesTotal}' : ''}',
                style: TextStyle(fontSize: 12, color: scheme.outline),
              ),
            ] else if (p.lastSyncedAt != null) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Icon(Icons.check_circle_outline, size: 14, color: scheme.primary),
                  const SizedBox(width: 6),
                  Text(
                    '已同步 · ${_time(p.lastSyncedAt!)}',
                    style: TextStyle(fontSize: 12, color: scheme.primary),
                  ),
                ],
              ),
            ],
            if (p.error != null) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                children: <Widget>[
                  Icon(Icons.error_outline, size: 14, color: scheme.error),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      p.error!,
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _time(DateTime t) {
    final l = t.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:'
        '${l.minute.toString().padLeft(2, '0')}:'
        '${l.second.toString().padLeft(2, '0')}';
  }
}

class _PeerTile extends StatelessWidget {
  const _PeerTile({
    required this.peer,
    required this.svc,
    required this.onConnect,
  });

  final DiscoveredPeer peer;
  final SyncService svc;
  final VoidCallback onConnect;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 连接状态：已连接 / 已配对（对端有密钥）/ 未连接
    final label = svc.netState == NetState.connected
        ? '已连接'
        : (peer.hasKey ? '已配对' : '未配对');

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Icon(Icons.devices_other, color: scheme.onPrimaryContainer),
      ),
      title: Text(peer.deviceName),
      subtitle: Text(
        '${peer.host}:${peer.port} · $label'
        '${peer.hasKey ? '' : ' · 需要在对方输入本机码'}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: FilledButton.tonal(
        onPressed: onConnect,
        child: Text(svc.hasMasterKey ? '重连' : '配对'),
      ),
      onTap: onConnect,
    );
  }
}
