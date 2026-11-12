import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:async';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../net/sync_service.dart';
import '../db/database.dart';
import '../providers.dart';
import '../theme/background_scaffold.dart';
import 'pairing_page.dart';

/// 设置页：设备名、主题（背景图 / 透明度 / 颜色）、同步、图片 GC、重置配对。
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final cfg = ref.watch(appConfigProvider);
    final theme = cfg.theme;
    final svc = ref.watch(syncServiceProvider);

    return BackgroundScaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        children: <Widget>[
          _section('设备'),
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: const Text('设备名'),
            subtitle: Text(cfg.deviceName),
            trailing: const Icon(Icons.edit_outlined, size: 18),
            onTap: _busy ? null : () => _editDeviceName(cfg.deviceName),
          ),
          ListTile(
            leading: const Icon(Icons.fingerprint),
            title: const Text('设备 ID'),
            subtitle: Text(
              cfg.deviceId,
              style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
            ),
          ),
          ListTile(
            leading: Icon(
              cfg.hasMasterKey ? Icons.lock_outline : Icons.lock_open_outlined,
            ),
            title: const Text('密钥状态'),
            subtitle: Text(
              cfg.hasMasterKey
                  ? '已生成 masterKey（存于系统安全存储）'
                  : '尚未生成，前往「配对」页',
            ),
          ),

          _section('主题'),
          ListTile(
            leading: const Icon(Icons.wallpaper),
            title: const Text('背景图片'),
            subtitle: Text(
              theme.backgroundImage ?? '未设置',
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (theme.backgroundImage != null)
                  IconButton(
                    tooltip: '清除',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _busy
                        ? null
                        : () => ref
                            .read(appConfigProvider.notifier)
                            .setBackgroundImage(null),
                  ),
                const Icon(Icons.image_outlined, size: 18),
              ],
            ),
            onTap: _busy ? null : _pickBackground,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '背景透明度：${theme.backgroundOpacity.toStringAsFixed(2)}',
                  style: const TextStyle(fontSize: 13),
                ),
                Slider(
                  value: theme.backgroundOpacity.clamp(0.0, 1.0),
                  min: 0,
                  max: 1,
                  divisions: 20,
                  label: theme.backgroundOpacity.toStringAsFixed(2),
                  onChanged: (v) => ref
                      .read(appConfigProvider.notifier)
                      .setTheme(theme.copyWith(backgroundOpacity: v)),
                ),
              ],
            ),
          ),
          _colorTile(
            '文字颜色',
            theme.textColor,
            (c) => ref
                .read(appConfigProvider.notifier)
                .setTheme(theme.copyWith(textColor: c)),
          ),
          _colorTile(
            '强调色',
            theme.accentColor,
            (c) => ref
                .read(appConfigProvider.notifier)
                .setTheme(theme.copyWith(accentColor: c)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.brightness_6_outlined),
            title: const Text('深色模式'),
            value: theme.isDark,
            onChanged: (v) => ref.read(appConfigProvider.notifier).setTheme(
                  theme.copyWith(brightness: v ? 'dark' : 'light'),
                ),
          ),

          _section('同步'),
          SwitchListTile(
            secondary: const Icon(Icons.sync),
            title: const Text('启用局域网同步'),
            subtitle: Text(svc.isAdvertising ? '正在广播' : '未广播'),
            value: cfg.syncEnabled,
            onChanged: (v) =>
                ref.read(appConfigProvider.notifier).setSyncEnabled(v),
          ),
          ListTile(
            leading: const Icon(Icons.qr_code_2),
            title: const Text('配对与密钥'),
            subtitle: const Text('显示配对码 / 重置配对'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const PairingPage(),
              ),
            ),
          ),

          _section('备份与导出'),
          ListTile(
            leading: const Icon(Icons.backup_outlined),
            title: const Text('立即备份数据库'),
            subtitle: const Text('VACUUM INTO backups/（每天首次编辑后自动执行）'),
            onTap: _busy ? null : _backupNow,
          ),
          ListTile(
            leading: const Icon(Icons.upload_file_outlined),
            title: const Text('导出全部为 md'),
            subtitle: const Text('含图片复制，产物可在外部编辑器直接打开'),
            onTap: _busy ? null : _exportAll,
          ),
          ListTile(
            leading: const Icon(Icons.restore_outlined),
            title: const Text('从备份恢复'),
            subtitle: const Text('列出 backups/ 下的备份文件'),
            onTap: _busy ? null : _restoreFromBackup,
          ),

          _section('维护'),
          ListTile(
            leading: const Icon(Icons.cleaning_services_outlined),
            title: const Text('图片垃圾回收'),
            subtitle: const Text('删除没有被任何笔记引用的图片'),
            onTap: _busy ? null : _runGc,
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('重建笔记索引'),
            subtitle: const Text('以文件为准修复元数据（标题、摘要、时间）'),
            onTap: _busy ? null : _rebuildIndex,
          ),

          const SizedBox(height: 28),
          Center(
            child: Text(
              '局域网记事本 0.1.0',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
          const SizedBox(height: 28),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
      );

  /// 颜色选择：用一组预设色 + 色相/明度滑杆，不引入额外依赖。
  Widget _colorTile(String label, String hex, void Function(String) onPick) {
    final presets = <String>[
      '#000000', '#FFFFFF', '#37474F', '#4A90D9',
      '#7B1FA2', '#C62828', '#2E7D32', '#EF6C00',
    ];
    return ListTile(
      leading: Container(
        width: 22,
        height: 22,
        decoration: BoxDecoration(
          color: _parse(hex),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        ),
      ),
      title: Text(label),
      subtitle: Text(hex, style: const TextStyle(fontSize: 12)),
      onTap: () async {
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            title: Text('选择$label'),
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: presets
                      .map(
                        (c) => InkWell(
                          onTap: () => Navigator.of(ctx).pop(c),
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: _parse(c),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Theme.of(ctx).colorScheme.outlineVariant,
                              ),
                            ),
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        );
        if (picked != null) onPick(picked);
      },
    );
  }

  static Color _parse(String hex) {
    var h = hex.replaceFirst('#', '');
    if (h.length == 6) h = 'FF$h';
    return Color(int.tryParse(h, radix: 16) ?? 0xFF000000);
  }

  Future<void> _editDeviceName(String current) async {
    final c = TextEditingController(text: current);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('设备名'),
        content: TextField(controller: c, autofocus: true),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(c.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    c.dispose();
    if (name == null || !mounted) return;
    await ref.read(appConfigProvider.notifier).setDeviceName(name);
    // 设备名变了要重新广播 TXT。
    await ref.read(syncServiceProvider).ensureMdns(force: true);
  }

  /// 背景图：复制到 `notepad/theme/`（**独立目录**，不进 assets/images）。
  Future<void> _pickBackground() async {
    setState(() => _busy = true);
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (picked == null) return;

      // 变更 4：主题背景落在 VaultPaths2.themeDir（不在 assets/images 下，
      // 因此不参与同步，也不会被图片 GC 清掉）。
      final paths = ref.read(vaultPathsProvider);
      final ext = p.extension(picked.path).replaceFirst('.', '').toLowerCase();
      final target = File(
        p.join(paths.themeDir.path, 'background.${ext.isEmpty ? 'jpg' : ext}'),
      );
      await target.parent.create(recursive: true);
      await target.writeAsBytes(await picked.readAsBytes(), flush: true);

      // 记录相对路径；同时清理其他扩展名的旧背景，避免残留占空间。
      for (final f in paths.themeDir.listSync().whereType<File>()) {
        if (f.path != target.path) await f.delete();
      }

      final rel = p.join('theme', p.basename(target.path));
      await ref.read(appConfigProvider.notifier).setBackgroundImage(rel);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('选择背景失败：$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 图片 GC：引用集合从数据库取（变更 1：正文入库）。
  Future<void> _runGc() async {
    setState(() => _busy = true);
    try {
      final notes = await ref.read(noteRepositoryProvider).all();
      final referenced = <String>{};
      for (final n in notes) {
        try {
          final decoded = jsonDecode(n.imageHashes);
          if (decoded is List) {
            referenced.addAll(decoded.map((e) => e.toString()));
          }
        } catch (_) {
          // 该行数据异常则跳过，不让 GC 因单条脏数据失败
        }
      }
      final n = await ref
          .read(imageVaultProvider)
          .collectGarbage(referencedHashes: referenced);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(n == 0 ? '没有需要清理的图片' : '已清理 ${n.toString()} 个未被引用的图片')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 立即执行一次 VACUUM INTO 备份（变更 8）。
  Future<void> _backupNow() async {
    setState(() => _busy = true);
    try {
      final paths = ref.read(vaultPathsProvider);
      final db = ref.read(databaseProvider);
      final target = paths.dailyBackup(DateTime.now());
      await db.backupTo(target);
      await paths.pruneBackups();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('备份完成：${target.path}')),
      );
    } catch (e) {
      if (!mounted) return;
      // 变更 9：备份失败必须提示用户
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('备份失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导出全部为 md（含图片）。
  Future<void> _exportAll() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(exporterProvider).exportAll();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '已导出 ${r.files} 篇、${r.imagesCopied} 张图片 → ${r.targetDir}',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导出失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 从备份恢复：列出备份文件供选择，然后替换数据库文件。
  Future<void> _restoreFromBackup() async {
    final paths = ref.read(vaultPathsProvider);
    final backups = paths.listBackups();
    if (backups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可用备份')),
      );
      return;
    }

    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择要恢复的备份'),
        children: backups
            .map(
              (f) => SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(f.path),
                child: Text(
                  '${p.basename(f.path)}（${(f.lengthSync() / 1024).toStringAsFixed(0)} KB）',
                ),
              ),
            )
            .toList(),
      ),
    );
    if (chosen == null || !mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认恢复？'),
        content: const Text('当前数据库将被备份文件替换，未备份的改动会丢失。'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    try {
      // 1) 先把当前库另存，避免误操作后无法回退（SQLite 的 WAL/SHM 也一并留在原地）
      final cur = paths.dbFile;
      if (cur.existsSync()) {
        await cur.copy(cur.path + '.before-restore');
      }

      // 2) 关掉当前库，把备份文件复制到位
      final old = ref.read(databaseProvider);
      await old.close();
      await File(chosen).copy(cur.path);

      // 3) **同进程内重开数据库**，而不是要求用户手动杀进程。
      //    重开后再让 provider 指向新实例，后续所有 DB 操作即可正常工作。
      final reopened = AppDatabase.atFile(cur);
      // 立刻做一次自检，尽早发现「备份文件损坏」这类问题
      final healthy = await reopened.isHealthy();
      await ref.read(databaseProvider.notifier).replaceWith(reopened);

      // 4) 清理可能的 -wal / -shm 残留（它们属于被替换掉的旧库）
      for (final suffix in <String>['-wal', '-shm']) {
        final f = File(cur.path + suffix);
        if (f.existsSync()) {
          try {
            await f.delete();
          } catch (_) {
            // 删不掉不影响使用。
          }
        }
      }

      // 5) 刷新列表
      unawaited(ref.read(notesListProvider.notifier).reload());

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            healthy
                ? '已恢复并重新加载数据库'
                : '已恢复，但完整性检查未通过，请检查备份文件',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('恢复失败：$e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rebuildIndex() async {
    setState(() => _busy = true);
    try {
      // 正文入库后不再需要「以文件为准重建索引」；这里改为重建搜索索引。
      await ref.read(searchServiceProvider).rebuild();
      await ref.read(notesListProvider.notifier).reload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('索引已重建')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
