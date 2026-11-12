import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../db/database.dart';
import '../providers.dart';
import '../theme/background_scaffold.dart';
import 'note_editor_page.dart';
import 'search_page.dart';
import 'settings_page.dart';

/// 笔记列表页：按 updatedAt 倒序，显示标题 + 摘要 + 时间。
class NotesListPage extends ConsumerWidget {
  const NotesListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notes = ref.watch(notesListProvider);

    return BackgroundScaffold(
      appBar: AppBar(
        title: const Text('局域网记事本'),
        actions: <Widget>[
          IconButton(
            tooltip: '搜索',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SearchPage()),
            ),
          ),
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.read(notesListProvider.notifier).reload(),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const SettingsPage()),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('新建'),
        onPressed: () async {
          final repo = ref.read(noteRepositoryProvider);
          final noteId = await repo.create();
          await ref.read(notesListProvider.notifier).reload();
          if (!context.mounted) return;
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => NoteEditorPage(noteId: noteId),
            ),
          );
          await ref.read(notesListProvider.notifier).reload();
        },
      ),
      body: notes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败：$e')),
        data: (list) {
          if (list.isEmpty) return const _EmptyState();
          return RefreshIndicator(
            onRefresh: () => ref.read(notesListProvider.notifier).reload(),
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: list.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) => _NoteTile(
                note: list[i],
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => NoteEditorPage(noteId: list[i].noteId),
                    ),
                  );
                  await ref.read(notesListProvider.notifier).reload();
                },
                onDelete: () => _confirmDelete(context, ref, list[i]),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Note note,
  ) async {
    final ok = await showModalBottomSheet<bool>(
      context: context,
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除笔记'),
              subtitle: const Text('图片会在下次垃圾回收时清理'),
              onTap: () => Navigator.of(context).pop(true),
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.of(context).pop(false),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    // 软删除：记录保留为墓碑，以便把删除动作同步给对端。
    await ref.read(noteRepositoryProvider).softDelete(note.noteId);
    await ref.read(notesListProvider.notifier).reload();
  }
}

/// 统计图片数量（image_hashes 是 JSON 数组文本）。
int imageCount(Note note) {
  try {
    final decoded = jsonDecode(note.imageHashes);
    return decoded is List ? decoded.length : 0;
  } catch (_) {
    return 0;
  }
}

class _NoteTile extends StatelessWidget {
  const _NoteTile({
    required this.note,
    required this.onTap,
    required this.onDelete,
  });

  final Note note;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      onTap: onTap,
      onLongPress: onDelete,
      title: Text(
        note.title.isEmpty ? '未命名' : note.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (note.excerpt.isNotEmpty)
            Text(
              note.excerpt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
            ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Text(
                _formatTime(note.updatedAt),
                style: TextStyle(fontSize: 11, color: scheme.outline),
              ),
              if (imageCount(note) > 0) ...<Widget>[
                const SizedBox(width: 8),
                Icon(Icons.image_outlined, size: 12, color: scheme.outline),
                Text(
                  '${imageCount(note)}',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ],
          ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.more_horiz),
        onPressed: onDelete,
      ),
    );
  }

  /// drift 的 Note.updatedAt 是 int 毫秒。
  static String _formatTime(int millis) {
    final local = DateTime.fromMillisecondsSinceEpoch(millis).toLocal();
    final now = DateTime.now();
    final sameDay =
        local.year == now.year && local.month == now.month && local.day == now.day;
    if (sameDay) return DateFormat('HH:mm').format(local);
    if (local.year == now.year) return DateFormat('MM-dd HH:mm').format(local);
    return DateFormat('yyyy-MM-dd').format(local);
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.note_add_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            const Text('还没有笔记'),
            const SizedBox(height: 4),
            Text(
              '点右下角「新建」开始',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ],
        ),
      );
}
