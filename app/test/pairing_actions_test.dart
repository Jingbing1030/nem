import 'package:flutter_test/flutter_test.dart';
import 'package:lan_notepad/src/net/pairing_actions.dart';

/// 「连接到设备」动作集合的测试。
///
/// 覆盖的 bug（用户实测反馈）：
/// **任何页面都找不到输入配对码的地方。**
///
/// 根因：输入框被写在 `if (!hasMasterKey)` 分支里，而 `main()` 首次启动就
/// 无条件生成 masterKey → `hasMasterKey` 恒为 true → 输入框永远不可达。
/// 两台设备各用各的密钥握手，必然失败。
void main() {
  group('connectActionsFor', () {
    test('本机没有密钥 → 只能输入配对码', () {
      final actions = connectActionsFor(hasMasterKey: false);
      expect(actions, <ConnectAction>[ConnectAction.pairWithCode]);
      expect(actions, isNot(contains(ConnectAction.reconnect)),
          reason: '没有密钥时无法 fast_auth，重连必然失败');
    });

    test('本机已有密钥 → 重连与输入配对码**都要有**', () {
      final actions = connectActionsFor(hasMasterKey: true);
      expect(actions, contains(ConnectAction.reconnect));
      expect(
        actions,
        contains(ConnectAction.pairWithCode),
        reason: '这是曾经出 bug 的地方：有密钥时也必须能输入对方的配对码，'
            '否则用户无从「加入另一台设备」',
      );
      expect(actions, hasLength(2));
    });
  });

  group('不变量：输入配对码永远可用', () {
    test('无论本机有没有密钥，都提供「输入配对码」', () {
      // 这是整个修复的核心不变量。
      for (final hasKey in <bool>[true, false]) {
        expect(
          pairingByCodeAlwaysAvailable(hasMasterKey: hasKey),
          isTrue,
          reason: 'hasMasterKey=$hasKey 时「输入配对码」不见了 —— '
              '说明决策规则被改回了有 bug 的形态（用户正是在这里卡住）',
        );
      }
    });

    test('退化检测：若哪天只按 hasMasterKey 走单一分支，本测试会失败', () {
      // 模拟「旧的有 bug 的实现」：有密钥时只给重连。
      List<ConnectAction> buggyFor(bool hasMasterKey) => hasMasterKey
          ? const <ConnectAction>[ConnectAction.reconnect]
          : const <ConnectAction>[ConnectAction.pairWithCode];

      // 旧实现在「有密钥」这个最常见的情况下丢掉了配对能力。
      expect(
        buggyFor(true).contains(ConnectAction.pairWithCode),
        isFalse,
        reason: '这描述了旧实现的行为，用于说明它为何是 bug',
      );
      // 而现在的实现在同样输入下必须给出配对能力。
      expect(
        connectActionsFor(hasMasterKey: true)
            .contains(ConnectAction.pairWithCode),
        isTrue,
      );
    });
  });

  group('ConnectAction 枚举', () {
    test('两个取值都存在，且 name 稳定（UI 用 name 传值）', () {
      expect(ConnectAction.reconnect.name, 'reconnect');
      expect(ConnectAction.pairWithCode.name, 'pairWithCode');
    });

    test('没有多余取值（UI 的对话框只处理这两个）', () {
      expect(ConnectAction.values, hasLength(2));
    });
  });
}
