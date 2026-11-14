/// 「连接到某台设备」时可供用户选择的动作。
///
/// 独立成纯 Dart 文件（不依赖 Flutter widget）是为了让这条**决策规则**
/// 能被单测直接覆盖 —— 它正是曾经出 bug 的地方（见 [connectActionsFor]）。
library;

/// 连接设备时可用的动作。
enum ConnectAction {
  /// 两台设备已配对过，用会话密钥直接重连（`fast_auth`）。
  reconnect,

  /// 输入对方显示的 6 位配对码（`pair_request`），首次建立信任。
  pairWithCode,
}

/// 决定「连接到设备」对话框应提供哪些动作。
///
/// ## 这条规则修的是什么
///
/// 早先的实现把「输入配对码」的入口写在 `if (!hasMasterKey)` 分支里：
///
/// ```dart
/// if (svc.hasMasterKey) { await svc.connectTo(peer); return; }  // 直接重连
/// // 只有没有密钥时才弹输入框 ↓
/// final code = await showDialog(...);
/// ```
///
/// 而 `main()` **首次启动就无条件生成 masterKey**，于是 `hasMasterKey` 恒为
/// `true` —— 那个输入配对码的对话框**永远不可达**。用户被提示「去输入对方的
/// 配对码」，却在任何页面都找不到输入框；两台设备各用各的密钥握手，必然失败。
///
/// **正确语义**：「本机有密钥」只意味着*本机可以当主机*，
/// **不意味着本机不能加入别人**。所以有密钥时必须同时给出两条路。
///
/// 无论哪种情况，「输入配对码」都必须在列 —— 这是本函数唯一的不变量，
/// 单测即围绕它展开。
List<ConnectAction> connectActionsFor({required bool hasMasterKey}) =>
    hasMasterKey
        ? const <ConnectAction>[
            ConnectAction.reconnect,
            ConnectAction.pairWithCode,
          ]
        : const <ConnectAction>[ConnectAction.pairWithCode];

/// 「输入配对码」是否始终可用。
///
/// 单独暴露一个布尔查询，方便在 UI 里断言/记录；它的返回值**恒为 true**，
/// 若哪天不再是，说明 [connectActionsFor] 被人改回了有 bug 的形态。
bool pairingByCodeAlwaysAvailable({required bool hasMasterKey}) =>
    connectActionsFor(hasMasterKey: hasMasterKey)
        .contains(ConnectAction.pairWithCode);
