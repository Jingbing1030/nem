import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:notepad_core/notepad_core.dart';

import '../images/image_picker_service.dart';
import '../images/image_vault.dart';
import '../log.dart';
import '../net/sync_service.dart';
import '../providers.dart';
import '../theme/background_scaffold.dart';
import 'markdown_preview.dart';

/// 编辑/预览/分屏 三态。
enum EditorMode {
  /// 仅编辑。
  edit,

  /// 仅预览。
  preview,

  /// 编辑 + 预览（仅平板/桌面，见 [supportsSplit]）。
  split,
}

/// 笔记编辑页。
///
/// - TextField（等宽字体）+ 工具栏
/// - 自动保存：输入停止 500ms 后写盘并更新 Isar `updatedAt`
/// - 分屏预览仅宽屏可用（需求 5.1）
class NoteEditorPage extends ConsumerStatefulWidget {
  const NoteEditorPage({super.key, required this.noteId});

  final String noteId;

  @override
  ConsumerState<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends ConsumerState<NoteEditorPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  Timer? _debounce;

  EditorMode _mode = EditorMode.edit;
  bool _loaded = false;
  bool _dirty = false;
  String? _savedAt;

  /// 自动保存防抖时长（需求 5.1）。
  static const Duration _debounceDelay = Duration(milliseconds: 500);

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // 变更 1：正文以 DB 为唯一真相源，直接读 notes.content。
    final db = ref.read(databaseProvider);
    final note = await db.noteById(widget.noteId);
    if (!mounted) return;
    _controller.text = note?.content ?? '';
    setState(() => _loaded = true);
  }

  void _onChanged() {
    _dirty = true;
    _debounce?.cancel();
    // 输入停止 500ms 后写盘。
    _debounce = Timer(_debounceDelay, _save);
  }

  Future<void> _save() async {
    if (!_loaded) return;
    final repo = ref.read(noteRepositoryProvider);
    await repo.saveContent(widget.noteId, _controller.text);
    _dirty = false;
    if (!mounted) return;
    setState(() {
      _savedAt = TimeOfDay.now().format(context);
    });
    // 列表页标题/摘要需要跟着变。
    unawaited(ref.read(notesListProvider.notifier).reload());

    // 需求 5.7：本地笔记变更（500ms 防抖后）触发增量同步。
    // 上面的 _debounceDelay 正是 500ms，与 ProtocolConst.editDebounceMs 一致，
    // 因此这里天然满足「防抖 500ms」的时序要求。
    unawaited(_notifyPeer());
  }

  /// 把本地变更推送给已连接的对端。
  ///
  /// 未连接 / 正在握手 / 对端掉线都属正常情况，因此单独兜住异常，
  /// 不让同步问题影响本地编辑体验。
  Future<void> _notifyPeer() async {
    try {
      await ref.read(syncServiceProvider).notifyLocalChange();
    } catch (e) {
      Log.debug('推送本地变更失败（可能未连接）：$e');
    }
  }

  /// 在光标处插入文本（工具栏与图片插入共用）。
  void _insertAtCursor(String text) {
    final sel = _controller.selection;
    final start = sel.start >= 0 ? sel.start : _controller.text.length;
    final end = sel.end >= 0 ? sel.end : start;

    if (start != end) {
      // 有选区：用新文本替换，并在两端补上标记时把选区包起来
      final selected = _controller.text.substring(start, end);
      _replaceRange(start, end, text.replaceFirst('§', selected));
      return;
    }
    _replaceRange(start, start, text.replaceAll('§', ''));
  }

  void _replaceRange(int start, int end, String text) {
    final value = _controller.value;
    final newText = value.text.replaceRange(start, end, text);
    _controller.value = value.copyWith(
      text: newText,
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  /// 工具栏：把选区用标记包裹（如 **加粗**）。
  void _wrapSelection(String before, String after) {
    final sel = _controller.selection;
    final text = _controller.text;
    final start = sel.start >= 0 ? sel.start : text.length;
    final end = sel.end >= 0 ? sel.end : start;
    final selected = text.substring(start, end);
    _replaceRange(start, end, '$before$selected$after');
  }

  /// 工具栏：在行首插入前缀（标题、列表）。
  void _prefixLine(String prefix) {
    final text = _controller.text;
    var pos = _controller.selection.start;
    if (pos < 0) pos = text.length;
    // 回到当前行行首
    final lineStart = text.lastIndexOf('\n', pos - 1) + 1;
    _replaceRange(lineStart, lineStart, prefix);
  }

  Future<void> _insertImageFromPicker() async {
    final picker = ref.read(imagePickerServiceProvider);
    final result = await picker.pickFromGalleryOrFiles();
    if (result == null) return;
    _insertImageRef(result);
  }

  Future<void> _pasteImageFromClipboard() async {
    final picker = ref.read(imagePickerServiceProvider);
    final result = await picker.pickFromClipboard();
    if (result == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板中没有图片')),
        );
      }
      return;
    }
    _insertImageRef(result);
  }

  /// 按需求在光标处插入 `![alt](assets/images/<hash>.<ext>)`。
  void _insertImageRef(ImageImportResult r) {
    final sel = _controller.selection;
    final cursor = sel.start >= 0 ? sel.start : _controller.text.length;
    final (newText, newCursor) = MarkdownDoc.insertImage(
      _controller.text,
      cursor,
      r.hash,
      r.ext,
    );
    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursor),
    );
    _onChanged();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(r.deduplicated ? '该图片已存在，直接引用' : '图片已保存'),
        ),
      );
    }
  }

  bool get _supportsSplit => MediaQuery.of(context).size.width >= 700;

  @override
  Widget build(BuildContext context) {
    final vaultRoot = ref.watch(vaultRootProvider) ?? '';

    if (!_loaded) {
      return const BackgroundScaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    final showEditor = _mode == EditorMode.edit || _mode == EditorMode.split;

    final editor = TextField(
      controller: _controller,
      focusNode: _focusNode,
      maxLines: null,
      expands: true,
      textAlignVertical: TextAlignVertical.top,
      keyboardType: TextInputType.multiline,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.5),
      decoration: const InputDecoration(
        border: InputBorder.none,
        contentPadding: EdgeInsets.all(16),
        hintText: '开始写下你的笔记…\n\n支持 Markdown：# 标题、**加粗**、- 列表、`代码`、![图片](…)',
      ),
    );

    final preview = MarkdownPreview(
      data: _controller.text,
      notesRoot: vaultRoot,
    );

    return BackgroundScaffold(
      appBar: AppBar(
        title: Text(_dirty ? '编辑中…' : (_savedAt == null ? '笔记' : '已保存 $_savedAt')),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert),
            onSelected: (v) async {
              if (v == 'export') {
                final r = await ref.read(exporterProvider).exportOne(widget.noteId);
                if (!context.mounted) return;
                final msg = r.files == 0
                    ? '导出失败：笔记不存在'
                    : '已导出到 ${r.targetDir}（含 ${r.imagesCopied} 张图片）';
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
              } else if (v == 'reimport') {
                await _insertImageFromPicker();
              }
            },
            itemBuilder: (_) => const <PopupMenuEntry<String>>[
              PopupMenuItem<String>(value: 'export', child: Text('导出为 md')),
              PopupMenuItem<String>(value: 'reimport', child: Text('插入图片')),
            ],
          ),
          IconButton(
            tooltip: '粘贴图片',
            icon: const Icon(Icons.content_paste_go),
            onPressed: _pasteImageFromClipboard,
          ),
          _ModeSwitcher(
            mode: _mode,
            supportsSplit: _supportsSplit,
            onChanged: (m) => setState(() => _mode = m),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          _Toolbar(
            onBold: () => _wrapSelection('**', '**'),
            onItalic: () => _wrapSelection('*', '*'),
            onStrike: () => _wrapSelection('~~', '~~'),
            onHeading: () => _prefixLine('# '),
            onBullet: () => _prefixLine('- '),
            onOrdered: () => _prefixLine('1. '),
            onTask: () => _prefixLine('- [ ] '),
            onQuote: () => _prefixLine('> '),
            onCode: () => _wrapSelection('`', '`'),
            onCodeBlock: () => _insertAtCursor('```\n§\n```'),
            onLink: () => _wrapSelection('[', '](https://)'),
            onTable: () => _insertAtCursor(
              '\n| 列 1 | 列 2 |\n| --- | --- |\n| 内容 | 内容 |\n',
            ),
            onImage: _insertImageFromPicker,
          ),
          const Divider(height: 1),
          Expanded(
            child: _mode == EditorMode.split
                ? Row(
                    children: <Widget>[
                      Expanded(child: editor),
                      const VerticalDivider(width: 1),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(8),
                          child: preview,
                        ),
                      ),
                    ],
                  )
                : showEditor
                    ? editor
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: preview,
                      ),
          ),
        ],
      ),
    );
  }
}

/// 编辑 / 预览 / 分屏 三态切换。
class _ModeSwitcher extends StatelessWidget {
  const _ModeSwitcher({
    required this.mode,
    required this.supportsSplit,
    required this.onChanged,
  });

  final EditorMode mode;
  final bool supportsSplit;
  final ValueChanged<EditorMode> onChanged;

  @override
  Widget build(BuildContext context) => PopupMenuButton<EditorMode>(
        icon: Icon(switch (mode) {
          EditorMode.edit => Icons.edit_outlined,
          EditorMode.preview => Icons.visibility_outlined,
          EditorMode.split => Icons.vertical_split_outlined,
        }),
        onSelected: onChanged,
        itemBuilder: (_) => <PopupMenuEntry<EditorMode>>[
          const PopupMenuItem(value: EditorMode.edit, child: Text('编辑')),
          const PopupMenuItem(value: EditorMode.preview, child: Text('预览')),
          PopupMenuItem(
            value: EditorMode.split,
            // 分屏仅平板/桌面可用。
            enabled: supportsSplit,
            child: Text(supportsSplit ? '分屏' : '分屏（屏幕过窄）'),
          ),
        ],
      );
}

/// 编辑工具栏。
class _Toolbar extends StatelessWidget {
  const _Toolbar({
    required this.onBold,
    required this.onItalic,
    required this.onStrike,
    required this.onHeading,
    required this.onBullet,
    required this.onOrdered,
    required this.onTask,
    required this.onQuote,
    required this.onCode,
    required this.onCodeBlock,
    required this.onLink,
    required this.onTable,
    required this.onImage,
  });

  final VoidCallback onBold;
  final VoidCallback onItalic;
  final VoidCallback onStrike;
  final VoidCallback onHeading;
  final VoidCallback onBullet;
  final VoidCallback onOrdered;
  final VoidCallback onTask;
  final VoidCallback onQuote;
  final VoidCallback onCode;
  final VoidCallback onCodeBlock;
  final VoidCallback onLink;
  final VoidCallback onTable;
  final VoidCallback onImage;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 46,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          children: <Widget>[
            _btn(context, Icons.format_bold, '加粗', onBold),
            _btn(context, Icons.format_italic, '斜体', onItalic),
            _btn(context, Icons.format_strikethrough, '删除线', onStrike),
            _btn(context, Icons.title, '标题', onHeading),
            _btn(context, Icons.format_list_bulleted, '无序列表', onBullet),
            _btn(context, Icons.format_list_numbered, '有序列表', onOrdered),
            _btn(context, Icons.checklist, '任务列表', onTask),
            _btn(context, Icons.format_quote, '引用', onQuote),
            _btn(context, Icons.code, '行内代码', onCode),
            _btn(context, Icons.data_object, '代码块', onCodeBlock),
            _btn(context, Icons.link, '链接', onLink),
            _btn(context, Icons.table_chart_outlined, '表格', onTable),
            _btn(context, Icons.image_outlined, '插入图片', onImage),
          ],
        ),
      );

  Widget _btn(
    BuildContext context,
    IconData icon,
    String tooltip,
    VoidCallback onTap,
  ) =>
      IconButton(
        icon: Icon(icon, size: 20),
        tooltip: tooltip,
        onPressed: onTap,
        visualDensity: VisualDensity.compact,
      );
}
