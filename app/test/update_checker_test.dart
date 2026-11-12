import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lan_notepad/src/update/release_info.dart';
import 'package:lan_notepad/src/update/update_checker.dart';
import 'package:lan_notepad/src/update/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 更新检测的端到端逻辑测试（不触网）：
/// 用 `MockClient` 伪造 GitHub API 的响应，验证
/// 「该弹 / 不该弹 / 跳过此版本 / 失败静默」四类行为。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 构造一个 GitHub Release 的 JSON（与本项目真实仓库字段一致）。
  String releaseJson({
    String tag = 'v0.3.0',
    String name = '0.3.0',
    String body = '- 新增：更新提示\n- 修复：若干问题',
    List<Map<String, Object?>>? assets,
  }) =>
      jsonEncode(<String, Object?>{
        'tag_name': tag,
        'name': name,
        'body': body,
        'html_url': 'https://github.com/Jingbing1030/nem/releases/tag/$tag',
        'published_at': '2026-11-01T10:00:00Z',
        'assets': assets ??
            <Map<String, Object?>>[
              <String, Object?>{
                'name': 'app-release.apk',
                'browser_download_url':
                    'https://github.com/Jingbing1030/nem/releases/download/'
                        '$tag/app-release.apk',
              },
            ],
      });

  /// 可编程的假 HTTP 客户端。
  http.Client fakeClient(
    Future<http.Response> Function(http.Request req) handler,
  ) =>
      MockClient(handler);

  /// GitHub 实际返回的是 `application/json; charset=utf-8`。
  ///
  /// ⚠️ 必须用 `Response.bytes` + 显式 charset：`http.Response(String, …)`
  /// 默认按 **latin1** 编码 body，带中文的 Release 说明会直接抛
  /// `Invalid argument (string): Contains invalid characters`。
  http.Response jsonResponse(String body, [int status = 200]) =>
      http.Response.bytes(
        utf8.encode(body),
        status,
        headers: const <String, String>{
          'content-type': 'application/json; charset=utf-8',
        },
      );

  Future<SharedPreferences> freshPrefs([Map<String, Object>? seed]) async {
    SharedPreferences.setMockInitialValues(seed ?? <String, Object>{});
    return SharedPreferences.getInstance();
  }

  Future<UpdateService> serviceWith({
    required http.Client client,
    String current = '0.2.0+1',
    Map<String, Object>? seed,
    DateTime Function()? now,
  }) async {
    final prefs = await freshPrefs(seed);
    return UpdateService(
      prefs: prefs,
      checker: UpdateChecker(client: client, now: now),
      currentVersionLoader: () async => current,
    );
  }

  group('UpdateChecker —— GitHub API 交互', () {
    test('请求 URL 正确且不携带 Authorization（公开仓库不留凭据）', () async {
      Uri? seen;
      Map<String, String>? headers;
      final checker = UpdateChecker(
        client: fakeClient((req) async {
          seen = req.url;
          headers = req.headers;
          return jsonResponse(releaseJson());
        }),
      );

      final info = await checker.fetchLatest();
      expect(seen.toString(),
          'https://api.github.com/repos/Jingbing1030/nem/releases/latest');
      expect(info, isNotNull);
      expect(info!.tagName, 'v0.3.0');
      expect(
        headers!.keys.map((k) => k.toLowerCase()),
        isNot(contains('authorization')),
      );
    });

    test('解析 assets 里的 APK 直链与 html_url', () async {
      final checker = UpdateChecker(
        client: fakeClient((_) async => jsonResponse(releaseJson())),
      );
      final info = await checker.fetchLatest();
      expect(info!.apkUrl, contains('app-release.apk'));
      expect(info.htmlUrl, contains('/releases/tag/v0.3.0'));
      expect(info.displayTitle, '0.3.0');
    });

    test('没有 apk asset 时 apkUrl 为 null，但 Release 仍可用', () async {
      final checker = UpdateChecker(
        client: fakeClient(
          (_) async => jsonResponse(
            releaseJson(assets: <Map<String, Object?>>[
              <String, Object?>{'name': 'source.zip'},
            ]),
          ),
        ),
      );
      final info = await checker.fetchLatest();
      expect(info, isNotNull);
      expect(info!.apkUrl, isNull);
    });

    test('403 限流 → 返回 null，不抛异常', () async {
      final checker = UpdateChecker(
        client: fakeClient(
          (_) async => jsonResponse(
            '{"message":"rate limit"}',
            403,
          ),
        ),
      );
      expect(await checker.fetchLatest(), isNull);
    });

    test('404（仓库还没发过 Release）→ 返回 null', () async {
      final checker = UpdateChecker(
        client: fakeClient((_) async => http.Response('Not Found', 404)),
      );
      expect(await checker.fetchLatest(), isNull);
    });

    test('网络异常（SocketException 等）→ 返回 null', () async {
      final checker = UpdateChecker(
        client: fakeClient((_) async => throw const SocketLikeError()),
      );
      expect(await checker.fetchLatest(), isNull);
    });

    test('超时 → 返回 null', () async {
      final checker = UpdateChecker(
        timeout: const Duration(milliseconds: 30),
        client: fakeClient((_) async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return jsonResponse(releaseJson());
        }),
      );
      expect(await checker.fetchLatest(), isNull);
    });

    test('JSON 结构不对（缺 tag_name）→ 返回 null', () async {
      final checker = UpdateChecker(
        client: fakeClient(
          (_) async => jsonResponse(jsonEncode(<String, Object?>{'x': 1})),
        ),
      );
      expect(await checker.fetchLatest(), isNull);
    });

    test('缓存：成功结果在 ttl 内不再打第二次请求（省 60/h 配额）', () async {
      var calls = 0;
      final checker = UpdateChecker(
        client: fakeClient((_) async {
          calls++;
          return jsonResponse(releaseJson());
        }),
      );
      await checker.fetchLatest();
      await checker.fetchLatest();
      await checker.fetchLatest();
      expect(calls, 1);
    });

    test('force: true 忽略缓存', () async {
      var calls = 0;
      final checker = UpdateChecker(
        client: fakeClient((_) async {
          calls++;
          return jsonResponse(releaseJson());
        }),
      );
      await checker.fetchLatest();
      await checker.fetchLatest(force: true);
      expect(calls, 2);
    });

    test('失败结果只在 failureTtl 内缓存（默认 30 分钟）', () async {
      var calls = 0;
      var clock = DateTime(2026, 11, 12, 10, 0);
      final checker = UpdateChecker(
        client: fakeClient((_) async {
          calls++;
          return http.Response('rate limit', 403);
        }),
        now: () => clock,
      );

      await checker.fetchLatest();
      clock = clock.add(const Duration(minutes: 5));
      await checker.fetchLatest();
      expect(calls, 1, reason: '30 分钟内不重试');

      clock = clock.add(const Duration(minutes: 40));
      await checker.fetchLatest();
      expect(calls, 2, reason: '失败缓存过期后允许重试');
    });
  });

  group('UpdateService —— 该不该弹', () {
    test('远端更新 → 返回 ReleaseInfo', () async {
      final svc = await serviceWith(
        client: fakeClient((_) async => jsonResponse(releaseJson())),
      );
      final info = await svc.checkForUpdate();
      expect(info, isNotNull);
      expect(info!.tagName, 'v0.3.0');
    });

    test('远端与当前相同 → null（不弹）', () async {
      final svc = await serviceWith(
        client: fakeClient(
          (_) async => jsonResponse(releaseJson(tag: 'v0.2.0')),
        ),
      );
      expect(await svc.checkForUpdate(), isNull);
    });

    test('远端更旧 → null（不弹）', () async {
      final svc = await serviceWith(
        client: fakeClient(
          (_) async => jsonResponse(releaseJson(tag: 'v0.1.0')),
        ),
      );
      expect(await svc.checkForUpdate(), isNull);
    });

    test('远端 0.10.0 > 当前 0.2.0 → 弹（位宽场景）', () async {
      final svc = await serviceWith(
        client: fakeClient(
          (_) async => jsonResponse(releaseJson(tag: 'v0.10.0')),
        ),
      );
      expect(await svc.checkForUpdate(), isNotNull);
    });

    test('网络失败 → null，且不抛异常（静默）', () async {
      final svc = await serviceWith(
        client: fakeClient((_) async => throw const SocketLikeError()),
      );
      expect(await svc.checkForUpdate(), isNull);
    });

    test('403 限流 → null', () async {
      final svc = await serviceWith(
        client: fakeClient((_) async => http.Response('limit', 403)),
      );
      expect(await svc.checkForUpdate(), isNull);
    });

    test('读当前版本号失败 → null（不阻塞启动）', () async {
      final prefs = await freshPrefs();
      final svc = UpdateService(
        prefs: prefs,
        checker: UpdateChecker(
          client: fakeClient((_) async => jsonResponse(releaseJson())),
        ),
        currentVersionLoader: () async => throw StateError('MethodChannel 不可用'),
      );
      expect(await svc.checkForUpdate(), isNull);
    });
  });

  group('「跳过此版本」', () {
    test('跳过后同版本不再提示', () async {
      final svc = await serviceWith(
        client: fakeClient(
          (_) async => jsonResponse(releaseJson(tag: 'v0.3.0')),
        ),
      );
      expect(await svc.checkForUpdate(), isNotNull);
      await svc.skip('v0.3.0');
      expect(svc.skippedVersion(), '0.3.0');
      expect(await svc.checkForUpdate(force: true), isNull);
    });

    test('跳过后更高版本仍要提示', () async {
      final svc = await serviceWith(
        client: fakeClient(
          (_) async => jsonResponse(releaseJson(tag: 'v0.3.1')),
        ),
        seed: <String, Object>{UpdateService.skippedVersionKey: '0.3.0'},
      );
      expect(await svc.checkForUpdate(), isNotNull);
    });

    test('跳过后更低版本也不提示（防降级提示）', () async {
      final svc = await serviceWith(
        client: fakeClient(
          (_) async => jsonResponse(releaseJson(tag: 'v0.2.9')),
        ),
        seed: <String, Object>{UpdateService.skippedVersionKey: '0.3.0'},
      );
      expect(await svc.checkForUpdate(), isNull);
    });

    test('跳过记录跨实例持久（走 shared_preferences）', () async {
      final first = await serviceWith(
        client: fakeClient((_) async => jsonResponse(releaseJson())),
      );
      await first.skip('0.3.0');

      // 模拟下次冷启动：仅重建服务，prefs 内容保留。
      final prefs = await SharedPreferences.getInstance();
      final second = UpdateService(
        prefs: prefs,
        checker: UpdateChecker(
          client: fakeClient(
            (_) async => jsonResponse(releaseJson(tag: 'v0.3.0')),
          ),
        ),
        currentVersionLoader: () async => '0.2.0+1',
      );
      expect(await second.checkForUpdate(), isNull);
    });

    test('跳过 nil/空值视为未跳过', () async {
      final svc = await serviceWith(
        client: fakeClient((_) async => jsonResponse(releaseJson())),
        seed: <String, Object>{UpdateService.skippedVersionKey: ''},
      );
      expect(svc.skippedVersion(), isNull);
      expect(await svc.checkForUpdate(), isNotNull);
    });

    test('clearSkip 后同版本重新提示', () async {
      final svc = await serviceWith(
        client: fakeClient((_) async => jsonResponse(releaseJson())),
        seed: <String, Object>{UpdateService.skippedVersionKey: '0.3.0'},
      );
      expect(await svc.checkForUpdate(), isNull);
      await svc.clearSkip();
      expect(await svc.checkForUpdate(force: true), isNotNull);
    });

    test('版本写法不同但等价（v0.3.0 / 0.3.0+7）也算同一版本，仍跳过', () async {
      final svc = await serviceWith(
        client: fakeClient(
          (_) async => jsonResponse(releaseJson(tag: 'v0.3.0+7')),
        ),
        seed: <String, Object>{UpdateService.skippedVersionKey: 'v0.3.0'},
      );
      expect(await svc.checkForUpdate(), isNull);
    });
  });

  group('当前版本归一化', () {
    test('0.2.0+1 → 0.2.0', () async {
      final svc = await serviceWith(
        client: fakeClient((_) async => jsonResponse(releaseJson())),
        current: '0.2.0+1',
      );
      expect(await svc.currentVersion(), '0.2.0');
    });
  });

  group('ReleaseInfo.fromJson —— 健壮性', () {
    test('非 Map 输入返回 null', () {
      expect(ReleaseInfo.fromJson(null), isNull);
      expect(ReleaseInfo.fromJson(<Object>[]), isNull);
      expect(ReleaseInfo.fromJson('v1.0.0'), isNull);
    });

    test('缺 html_url 时用 tag 拼兜底地址', () {
      final info = ReleaseInfo.fromJson(<String, Object?>{'tag_name': 'v9.9.9'});
      expect(info, isNotNull);
      expect(info!.htmlUrl, contains('/releases/tag/v9.9.9'));
    });

    test('name 为空时展示 tag', () {
      final info = ReleaseInfo.fromJson(<String, Object?>{
        'tag_name': 'v5.0.0',
        'name': '',
        'html_url': 'https://example.com',
      });
      expect(info!.displayTitle, 'v5.0.0');
    });
  });
}

/// 模拟底层网络错误（不在测试里直接 import dart:io，保持跨平台可跑）。
class SocketLikeError implements Exception {
  const SocketLikeError();

  @override
  String toString() => 'SocketException: 模拟网络不可用';
}
