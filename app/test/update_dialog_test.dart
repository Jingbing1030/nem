import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lan_notepad/src/update/release_info.dart';
import 'package:lan_notepad/src/update/startup_update_check.dart';
import 'package:lan_notepad/src/update/update_checker.dart';
import 'package:lan_notepad/src/update/update_dialog.dart';
import 'package:lan_notepad/src/update/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UI 层测试：
/// 1. 弹窗内容与三个按钮的行为；
/// 2. [StartupUpdateCheck] **不阻塞首屏** —— 子 widget 立刻可见，
///    请求在延迟之后才发出。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  http.Client okClient(String tag) => MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(jsonEncode(<String, Object?>{
            'tag_name': tag,
            'name': '更新到 $tag',
            'body': '## 更新说明\n\n- 第一条\n- 第二条',
            'html_url':
                'https://github.com/Jingbing1030/nem/releases/tag/$tag',
            'assets': <Map<String, Object?>>[
              <String, Object?>{
                'name': 'app-release.apk',
                'browser_download_url': 'https://example.com/app-release.apk',
              },
            ],
          })),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        ),
      );

  http.Client failingClient() =>
      MockClient((_) async => http.Response('rate limit', 403));

  Future<UpdateService> makeService(
    http.Client client, {
    Map<String, Object>? seed,
  }) async {
    SharedPreferences.setMockInitialValues(seed ?? <String, Object>{});
    final prefs = await SharedPreferences.getInstance();
    return UpdateService(
      prefs: prefs,
      checker: UpdateChecker(client: client),
      currentVersionLoader: () async => '0.2.0+1',
    );
  }

  ReleaseInfo sampleInfo({String tag = 'v0.3.0'}) => ReleaseInfo(
        tagName: tag,
        htmlUrl: 'https://github.com/Jingbing1030/nem/releases/tag/$tag',
        name: '0.3.0',
        body: '更新说明正文',
      );

  group('更新弹窗', () {
    testWidgets('显示新版本号、更新说明与三个按钮', (tester) async {
      final svc = await makeService(okClient('v0.3.0'));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showUpdateDialog(
                  ctx,
                  info: sampleInfo(),
                  service: svc,
                  launcher: (_) async => true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('发现新版本 v0.3.0'), findsOneWidget);
      expect(find.text('更新说明正文'), findsOneWidget);
      expect(find.text('去下载'), findsOneWidget);
      expect(find.text('稍后'), findsOneWidget);
      expect(find.text('跳过此版本'), findsOneWidget);
    });

    testWidgets('「去下载」跳转到 Release 页面', (tester) async {
      final svc = await makeService(okClient('v0.3.0'));
      Uri? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showUpdateDialog(
                  ctx,
                  info: sampleInfo(),
                  service: svc,
                  launcher: (uri) async {
                    opened = uri;
                    return true;
                  },
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('去下载'));
      await tester.pumpAndSettle();

      expect(opened.toString(),
          'https://github.com/Jingbing1030/nem/releases/tag/v0.3.0');
      expect(find.text('发现新版本 v0.3.0'), findsNothing);
    });

    testWidgets('「稍后」只关闭弹窗，不写跳过记录', (tester) async {
      final svc = await makeService(okClient('v0.3.0'));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showUpdateDialog(
                  ctx,
                  info: sampleInfo(),
                  service: svc,
                  launcher: (_) async => true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();

      expect(find.text('发现新版本 v0.3.0'), findsNothing);
      expect(svc.skippedVersion(), isNull);
    });

    testWidgets('「跳过此版本」写入记录', (tester) async {
      final svc = await makeService(okClient('v0.3.0'));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showUpdateDialog(
                  ctx,
                  info: sampleInfo(),
                  service: svc,
                  launcher: (_) async => true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('跳过此版本'));
      await tester.pumpAndSettle();

      expect(svc.skippedVersion(), '0.3.0');
      // 跳过之后同一版本不再提示。
      expect(await svc.checkForUpdate(force: true), isNull);
    });

    testWidgets('打不开浏览器时给出 SnackBar 提示而非崩溃', (tester) async {
      final svc = await makeService(okClient('v0.3.0'));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showUpdateDialog(
                  ctx,
                  info: sampleInfo(),
                  service: svc,
                  launcher: (_) async => false,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('去下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.textContaining('无法打开浏览器'), findsOneWidget);
    });

    testWidgets('launcher 抛异常时也不崩（静默 + 提示）', (tester) async {
      final svc = await makeService(okClient('v0.3.0'));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showUpdateDialog(
                  ctx,
                  info: sampleInfo(),
                  service: svc,
                  launcher: (_) async => throw StateError('没有浏览器'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('去下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(tester.takeException(), isNull);
      expect(find.textContaining('无法打开浏览器'), findsOneWidget);
    });

    testWidgets('超长 Release body 被截断，弹窗不溢出', (tester) async {
      final svc = await makeService(okClient('v0.3.0'));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) => Scaffold(
              body: TextButton(
                onPressed: () => showUpdateDialog(
                  ctx,
                  info: ReleaseInfo(
                    tagName: 'v0.3.0',
                    htmlUrl: 'https://example.com',
                    body: List<String>.generate(200, (i) => '第 $i 行').join('\n'),
                  ),
                  service: svc,
                  launcher: (_) async => true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.textContaining('…'), findsOneWidget);
    });
  });

  group('StartupUpdateCheck —— 不阻塞首屏', () {
    testWidgets('子 widget 立即渲染，弹窗在延迟之后才出现', (tester) async {
      final svc = await makeService(okClient('v0.3.0'));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            updateServiceProvider.overrideWith((ref) async => svc),
          ],
          child: const MaterialApp(
            home: StartupUpdateCheck(
              delay: Duration(milliseconds: 300),
              child: Scaffold(body: Text('首页内容')),
            ),
          ),
        ),
      );

      // 首帧：内容已经在，没有任何弹窗、没有 loading 阻塞。
      await tester.pump();
      expect(find.text('首页内容'), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);

      // 延迟未到 → 仍然不弹。
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(AlertDialog), findsNothing);

      // 延迟到点 → 弹出更新提示。
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      expect(find.text('发现新版本 v0.3.0'), findsOneWidget);
    });

    testWidgets('没有新版本时不弹任何东西', (tester) async {
      final svc = await makeService(okClient('v0.2.0'));

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            updateServiceProvider.overrideWith((ref) async => svc),
          ],
          child: const MaterialApp(
            home: StartupUpdateCheck(
              delay: Duration(milliseconds: 10),
              child: Scaffold(body: Text('首页内容')),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text('首页内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('网络失败/限流时静默，不弹窗也不报错', (tester) async {
      final svc = await makeService(failingClient());

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            updateServiceProvider.overrideWith((ref) async => svc),
          ],
          child: const MaterialApp(
            home: StartupUpdateCheck(
              delay: Duration(milliseconds: 10),
              child: Scaffold(body: Text('首页内容')),
            ),
          ),
        ),
      );

      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
