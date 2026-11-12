import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:notepad_core/notepad_core.dart';

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
                    FilledButton.icon(
                      icon: const Icon(Icons.vpn_key),
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
