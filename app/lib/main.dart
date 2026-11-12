import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:notepad_core/notepad_core.dart';

import 'src/config/config_store.dart';
import 'src/db/database.dart';
import 'src/db/note_repository.dart';
import 'src/db/paths.dart';
import 'src/images/image_vault.dart';
import 'src/log.dart';
import 'src/net/sync_service.dart';
import 'src/providers.dart';
import 'src/theme/theme_config_provider.dart';
import 'src/ui/notes_list_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. 目录结构（首次启动创建 notepad/ 及子目录）
  //    变更 4：md 文件不再是常驻存储，目录布局由 VaultPaths2 决定。
  final paths = await VaultPaths2.open();

  // 2. 配置与密钥
  final configStore = await ConfigStore.open();
  var config = await configStore.load();

  // 3. 首次启动生成 masterKey（需求 5.5 第 1 步）。
  //    密钥只进 secure_storage；shared_preferences 里只有 hasMasterKey 标记。
  if (!await configStore.hasMasterKey()) {
    await configStore.writeMasterKey(Kdf.generateMasterKey());
    config = config.copyWith(hasMasterKey: true);
    await configStore.save(config);
    Log.debug('已生成 masterKey（存于安全存储）');
  }

  // 4. 数据库：正文 + 元数据 + 同步基线 + FTS 全在同一个 SQLite 库
  //    （变更 1 / 变更 3：正文入库，md 只是导出产物）。
  final db = AppDatabase.atFile(paths.dbFile);

  // 5. 启动自检（变更 9）：必须跑 PRAGMA integrity_check。
  try {
    final check = await db.integrityCheck();
    if (!check.toLowerCase().contains('ok')) {
      Log.error('数据库完整性检查未通过: $check');
    }
  } catch (e) {
    Log.error('数据库完整性检查失败', e);
  }
  await db.enableForeignKeys();

  // 6. 仓库：正文读写以 DB 为唯一真相源。
  final repo = NoteRepository2(
    db: db,
    paths: paths,
    deviceId: config.deviceId,
  );
  final imageVault = ImageVault(paths);

  // 7. 网络与同步。
  final syncService = SyncService(
    configStore: configStore,
    repo: repo,
    paths: paths,
    imageVault: imageVault,
    deviceId: config.deviceId,
    deviceName: config.deviceName,
  );

  // 8. 生命周期：前台启动广播/监听，后台停止（需求 5.6）
  WidgetsBinding.instance.addObserver(_LifecycleCoordinator(syncService));

  if (config.syncEnabled) {
    unawaited(syncService.start());
  }

  runApp(
    ProviderScope(
      // 不写 `<Override>` 显式类型参数：flutter_riverpod 3.5.0 的主入口
      // 不再导出 `Override`（它搬到了 `flutter_riverpod/misc.dart`），
      // 而两个字面量都能自然推断出元素类型。
      overrides: [
        configStoreProvider.overrideWithValue(configStore),
        databaseProvider.overrideWith(() => DatabaseNotifier(db)),
        vaultPathsProvider.overrideWithValue(paths),
        noteRepositoryProvider.overrideWithValue(repo),
        imageVaultProvider.overrideWithValue(imageVault),
        syncServiceProvider.overrideWithValue(syncService),
        appConfigProvider.overrideWith(() => AppConfigNotifier(config)),
      ],
      child: const LanNotepadApp(),
    ),
  );
}

/// 应用根 Widget。
class LanNotepadApp extends ConsumerWidget {
  const LanNotepadApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(themeConfigProvider);
    return MaterialApp(
      title: '局域网记事本',
      debugShowCheckedModeBanner: false,
      theme: buildThemeData(theme),
      home: const NotesListPage(),
    );
  }
}

/// 前后台切换时启停广播与监听。
class _LifecycleCoordinator with WidgetsBindingObserver {
  _LifecycleCoordinator(this.service);

  final SyncService service;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // 回前台：恢复广播与监听。
        unawaited(service.start());
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // 进后台：停止广播与监听（省电，也避免后台被系统杀时留下半开连接）。
        unawaited(service.stop());
      case AppLifecycleState.inactive:
        break;
    }
  }
}
