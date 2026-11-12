import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'config/app_config.dart';
import 'config/config_store.dart';
import 'db/database.dart';
import 'db/note_repository.dart';
import 'db/paths.dart';
import 'export/md_exporter.dart';
import 'images/image_vault.dart';
import 'search/search_service.dart';

/// 基础设施 Provider 都在 `main()` 中用真实实例 override；
/// 未 override 即属编程错误，故直接抛错而不是给假实现。
final configStoreProvider = Provider<ConfigStore>(
  (ref) => throw StateError('configStoreProvider 必须在 main() 中 override'),
);

/// 数据库持有者。
///
/// **为什么不是普通 Provider**：「从备份恢复」需要在运行期关闭旧库、
/// 打开新库，并让所有下游 provider 拿到新实例。普通 `Provider` 一旦被
/// override 就无法在运行期替换，恢复后应用会停在「库已关闭」的坏状态
/// （用户必须手动杀进程才能恢复）。因此这里用可替换的 Notifier。
class DatabaseNotifier extends Notifier<AppDatabase> {
  DatabaseNotifier(this._seed);

  final AppDatabase _seed;

  @override
  AppDatabase build() => _seed;

  /// 在运行期替换数据库实例。
  ///
  /// 调用方负责先把新的数据库文件就位（例如从备份复制过来）。
  /// 这里**先切换状态再关旧库**：避免中途有查询打到已关闭的连接上。
  Future<void> replaceWith(AppDatabase next) async {
    final old = state;
    state = next;
    try {
      await old.close();
    } catch (_) {
      // 旧库可能已关闭，忽略。
    }
  }
}

final databaseProvider = NotifierProvider<DatabaseNotifier, AppDatabase>(
  () => throw StateError('databaseProvider 必须在 main() 中 override'),
);

final vaultPathsProvider = Provider<VaultPaths2>(
  (ref) => throw StateError('vaultPathsProvider 必须在 main() 中 override'),
);

final noteRepositoryProvider = Provider<NoteRepository2>(
  (ref) => NoteRepository2(
    db: ref.watch(databaseProvider),
    paths: ref.watch(vaultPathsProvider),
    deviceId: ref.watch(appConfigProvider).deviceId,
  ),
);

/// 图片仓库（内容寻址，逻辑不变）。
final imageVaultProvider = Provider<ImageVault>(
  (ref) => ImageVault(ref.watch(vaultPathsProvider)),
);

/// md 导出。
final exporterProvider = Provider<MdExporter>(
  (ref) => MdExporter(ref.watch(databaseProvider), ref.watch(vaultPathsProvider)),
);

/// 搜索（阶段 1 用 LIKE 实现，可切 FTS5）。
final searchServiceProvider = Provider<SearchService>(
  (ref) => LikeSearchService(ref.watch(databaseProvider)),
);

/// 笔记库根目录（背景图解析需要）。
final vaultRootProvider = Provider<String?>(
  (ref) => ref.watch(vaultPathsProvider).root.path,
);

/// 应用配置。
class AppConfigNotifier extends Notifier<AppConfig> {
  AppConfigNotifier([this._seed]);

  final AppConfig? _seed;

  @override
  AppConfig build() {
    final seed = _seed;
    if (seed == null) {
      throw StateError('AppConfigNotifier 必须通过 overrideWith 注入初始配置');
    }
    return seed;
  }

  void _commit(AppConfig next) {
    state = next;
    // 持久化失败不应让 UI 崩溃。
    ref.read(configStoreProvider).save(next).catchError((_) {});
  }

  Future<void> setDeviceName(String name) async => _commit(
        _store.copyWith(
          deviceName: name.trim().isEmpty ? '未命名设备' : name.trim(),
        ),
      );

  AppConfig get _store => state;

  Future<void> setTheme(ThemeConfig theme) async =>
      _commit(_store.copyWith(theme: theme));

  Future<void> setSyncEnabled(bool enabled) async =>
      _commit(_store.copyWith(syncEnabled: enabled));

  Future<void> setHasMasterKey(bool value) async =>
      _commit(_store.copyWith(hasMasterKey: value));

  Future<void> setBackgroundImage(String? relativePath) async => _commit(
        _store.copyWith(
          theme: _store.theme.copyWith(
            backgroundImage: relativePath,
            clearBackground: relativePath == null,
          ),
        ),
      );
}

final appConfigProvider = NotifierProvider<AppConfigNotifier, AppConfig>(
  AppConfigNotifier.new,
);

/// 主题配置（修改即时生效）。
final themeConfigProvider = Provider<ThemeConfig>(
  (ref) => ref.watch(appConfigProvider).theme,
);

/// 笔记列表（按 updatedAt 倒序，排除墓碑）。
class NotesListNotifier extends AsyncNotifier<List<Note>> {
  @override
  Future<List<Note>> build() =>
      ref.watch(noteRepositoryProvider).visibleNotes();

  Future<void> reload() async {
    state = const AsyncValue<List<Note>>.loading();
    state = await AsyncValue.guard(
      () => ref.read(noteRepositoryProvider).visibleNotes(),
    );
  }
}

final notesListProvider =
    AsyncNotifierProvider<NotesListNotifier, List<Note>>(NotesListNotifier.new);

/// 搜索状态。
class SearchQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String q) => state = q;
}

final searchQueryProvider =
    NotifierProvider<SearchQueryNotifier, String>(SearchQueryNotifier.new);

/// 搜索结果（查询为空时返回全部）。
final searchResultsProvider = FutureProvider<List<Note>>((ref) async {
  final q = ref.watch(searchQueryProvider);
  if (q.trim().isEmpty) {
    return ref.watch(noteRepositoryProvider).visibleNotes();
  }
  return ref.watch(searchServiceProvider).search(q);
});
