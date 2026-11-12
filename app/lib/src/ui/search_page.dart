import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../providers.dart';
import '../theme/background_scaffold.dart';
import 'note_editor_page.dart';

/// 搜索页（变更 7）。
///
/// - 输入防抖 250ms（文档要求 200~300ms）
/// - 结果按「标题命中优先 + updatedAt 倒序」排序（由 SearchService 保证）
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  static const Duration _debounce = Duration(milliseconds: 250);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 带防抖地更新查询（避免每敲一个字都查库）。
  void _onChanged(String value) {
    setState(() {});
    Future<void>.delayed(_debounce, () {
      if (!mounted) return;
      // 只有值仍是当前输入时才提交，避免过期结果覆盖
      if (_controller.text == value) {
        ref.read(searchQueryProvider.notifier).set(value);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final results = ref.watch(searchResultsProvider);
    final scheme = Theme.of(context).colorScheme;

    return BackgroundScaffold(
      appBar: AppBar(
        title: TextField(
          controller: _controller,
          autofocus: true,
          onChanged: _onChanged,
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: '搜索标题与正文…',
          ),
        ),
        actions: <Widget>[
          if (_controller.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () {
                _controller.clear();
                ref.read(searchQueryProvider.notifier).set('');
                setState(() {});
              },
            ),
        ],
      ),
      body: results.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('搜索失败：$e')),
        data: (list) {
          if (_controller.text.trim().isEmpty) {
            return Center(
              child: Text(
                '输入关键词开始搜索',
                style: TextStyle(color: scheme.outline),
              ),
            );
          }
          if (list.isEmpty) {
            return Center(
              child: Text('没有匹配的笔记', style: TextStyle(color: scheme.outline)),
            );
          }
          return ListView.separated(
            itemCount: list.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (_, i) {
              final n = list[i];
              return ListTile(
                title: _Highlighted(text: n.title.isEmpty ? '未命名' : n.title),
                subtitle: Text(
                  n.excerpt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                ),
                trailing: Text(
                  DateFormat('MM-dd').format(
                    DateTime.fromMillisecondsSinceEpoch(n.updatedAt),
                  ),
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => NoteEditorPage(noteId: n.noteId),
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

/// 高亮标题中的命中片段。
class _Highlighted extends StatelessWidget {
  const _Highlighted({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontWeight: FontWeight.w600),
      );
}
