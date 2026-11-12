import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../net/mdns_service.dart';
import '../net/net_service.dart';
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

  /// 连接流程：若本机已有密钥 → 直接 fast_auth 重连；
  /// 否则弹输入框让用户输入对端的 6 位码。
  Future<void> _connectFlow(
    BuildContext context,
    DiscoveredPeer peer,
    SyncService svc,
  ) async {
    if (svc.hasMasterKey) {
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

    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => const _CodeInputDialog(),
    );
    if (code == null) return;
    try {
      await svc.connectTo(peer, pairingCode: code);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配对成功，已开始同步')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('配对失败：$e')),
      );
    }
  }
}

/// 6 位配对码输入框。
class _CodeInputDialog extends StatefulWidget {
  const _CodeInputDialog();

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
            const Text('请输入对端设备上显示的 6 位数字'),
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
