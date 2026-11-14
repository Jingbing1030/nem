import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:notepad_core/notepad_core.dart';

import '../net/mdns_service.dart';
import '../net/sync_service.dart';
import '../providers.dart';
import '../theme/background_scaffold.dart';

/// 配对页：本机有 masterKey 时显示 6 位码（每 30s 刷新），
/// 否则提示由本机发起配对去索取密钥。
class PairingPage extends ConsumerStatefulWidget {
  const PairingPage({super.key});

  @override
  ConsumerState<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends ConsumerState<PairingPage> {
  String? _code;
  int _remaining = 0;
  Timer? _ticker;
  String? _deviceName;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    // 每秒刷新倒计时，跨步时更新码。
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final svc = ref.read(syncServiceProvider);
    final code = await svc.currentPairingCode();
    if (!mounted) return;
    setState(() {
      _code = code;
      _remaining = PairingHandshake.secondsRemaining();
      _deviceName = ref.read(appConfigProvider).deviceName;
    });
  }

  void _tick() {
    if (!mounted) return;
    final r = PairingHandshake.secondsRemaining();
    setState(() => _remaining = r);
    // 跨过步边界时重算码
    if (r == ProtocolConst.totpPeriod) unawaited(_refresh());
  }

  @override
  Widget build(BuildContext context) {
    final svc = ref.watch(syncServiceProvider);
    final scheme = Theme.of(context).colorScheme;

    return BackgroundScaffold(
      appBar: AppBar(title: const Text('配对')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: <Widget>[
          if (_code == null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: <Widget>[
                    Icon(Icons.key_off_outlined, size: 44, color: scheme.outline),
                    const SizedBox(height: 12),
                    const Text('本机还没有密钥', style: TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Text(
                      '本机是全新设备。请在「设备」页选择一台已配对设备连接，'
                      '并输入对方显示的 6 位配对码。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                    ),
                    const SizedBox(height: 16),
                    // 用户最容易卡住的地方：被告知"去输入对方的码"，
                    // 却在这一页找不到输入入口。这里直接给按钮。
                    FilledButton.icon(
                      icon: const Icon(Icons.vpn_key),
                      label: const Text('输入对方设备的配对码'),
                      onPressed: () => _joinByCode(context, svc),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      '— 或者 —',
                      style: TextStyle(color: scheme.outline, fontSize: 11),
                    ),
                    const SizedBox(height: 14),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.add_moderator_outlined),
                      label: const Text('在本机生成密钥（成为主机）'),
                      onPressed: () async {
                        await svc.ensureMasterKey();
                        await _refresh();
                      },
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '生成后本机将成为可被配对的主机，其他设备可用本机显示的码加入。',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.outline, fontSize: 11),
                    ),
                  ],
                ),
              ),
            )
          else ...<Widget>[
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Column(
                  children: <Widget>[
                    Text(
                      '在另一台设备上输入此配对码',
                      style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
                    ),
                    const SizedBox(height: 18),
                    // 6 位码：大号等宽、字母间距拉开，便于朗读与输入
                    Text(
                      _formatCode(_code!),
                      style: const TextStyle(
                        fontSize: 40,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w700,
                        letterSpacing: 6,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            value: _remaining / ProtocolConst.totpPeriod,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '$_remaining 秒后刷新',
                          style: TextStyle(color: scheme.outline, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.badge_outlined),
                    title: const Text('本机设备名'),
                    subtitle: Text(_deviceName ?? '-'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.wifi_tethering),
                    title: const Text('服务状态'),
                    subtitle: Text(
                      '${svc.isAdvertising ? '正在广播' : '未广播'}'
                      '${svc.port != 0 ? '（端口 ${svc.port}）' : ''}',
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(Icons.warning_amber_outlined, color: scheme.error),
                    title: const Text('重置配对'),
                    subtitle: const Text('生成新密钥，所有设备需重新配对'),
                    onTap: () => _confirmReset(context, svc),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // 本机已有密钥，但仍可能想加入另一台设备（例如这台才是"新手"）。
            // 不能因为 hasMasterKey 为 true 就藏掉这个入口 —— 那正是此前的 bug。
            Card(
              child: ListTile(
                leading: const Icon(Icons.login),
                title: const Text('输入对方设备的配对码'),
                subtitle: const Text('加入另一台设备（将改用对方的密钥）'),
                trailing: const Icon(Icons.chevron_right, size: 20),
                onTap: () => _joinByCode(context, svc),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '说明：配对码由 masterKey 派生（RFC 6238 TOTP，HMAC-SHA1），'
              '每 30 秒自动更换。配对码只用于首次建立信任，'
              '之后的通信一律使用由 masterKey 派生的会话密钥。',
              style: TextStyle(color: scheme.outline, fontSize: 11, height: 1.6),
            ),
          ],
        ],
      ),
    );
  }

  /// 让本机「加入」另一台设备：输入对方显示的 6 位码。
  ///
  /// 走与「设备」页相同的配对流程（`pair_request` + HMAC 证明）。
  /// 若本机已有密钥，配对成功后会被对方的密钥替换 —— 必须先让用户确认。
  Future<void> _joinByCode(BuildContext context, SyncService svc) async {
    final peers = svc.peers;
    if (peers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('尚未发现局域网设备，请先到「设备与配对」页查看'),
        ),
      );
      return;
    }

    final peer = await showDialog<DiscoveredPeer>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择要加入的设备'),
        children: peers
            .map(
              (d) => SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(d),
                child: ListTile(
                  leading: const Icon(Icons.devices_other),
                  title: Text(d.deviceName),
                  subtitle: Text('${d.host}:${d.port}'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            )
            .toList(),
      ),
    );
    if (peer == null || !context.mounted) return;

    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => _JoinCodeDialog(peerName: peer.deviceName),
    );
    if (code == null || !context.mounted) return;

    if (svc.hasMasterKey) {
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

  static String _formatCode(String code) =>
      code.length == 6 ? '${code.substring(0, 3)} ${code.substring(3)}' : code;

  Future<void> _confirmReset(BuildContext context, SyncService svc) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重置配对？'),
        content: const Text(
          '将生成新的 masterKey 并断开所有连接。'
          '其他设备必须重新配对才能同步。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await svc.resetMasterKey();
    await _refresh();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已重置，其他设备需重新配对')),
    );
  }
}


/// 6 位配对码输入框（用于「加入对方设备」）。
///
/// 与 `devices_page.dart` 里的同名对话框逻辑一致；这里单独一份是为了
/// 避免 UI 层互相依赖 —— 两页都可以独立打开。
class _JoinCodeDialog extends StatefulWidget {
  const _JoinCodeDialog({this.peerName});

  final String? peerName;

  @override
  State<_JoinCodeDialog> createState() => _JoinCodeDialogState();
}

class _JoinCodeDialogState extends State<_JoinCodeDialog> {
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
              '配对码在对方的「本机配对码」页显示，每 30 秒自动更换。',
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
