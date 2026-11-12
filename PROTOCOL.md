# 局域网记事本 — 同步协议规范 v1

本文档描述两台设备之间通过局域网 WebSocket 通信的消息格式、握手流程与同步算法。
实现代码见 `packages/notepad_core`（纯 Dart，不依赖 Flutter，可独立跑单测）。

---

## 1. 发现（mDNS / DNS-SD）

| 项 | 值 |
| --- | --- |
| 服务类型 | `_notepad._tcp.local` |
| TXT 记录 | `deviceName` / `deviceId` / `port` / `hasKey` |

- `deviceId`：UUID v4，设备唯一标识，安装时生成并持久化。
- `port`：WebSocket 监听端口。**动态分配**（`bind(port: 0)`）后写入 TXT，
  避免多设备固定端口冲突。
- `hasKey`：`"1"` 表示该设备已生成 masterKey（已有笔记库），`"0"` 表示全新设备。
  客户端据此提示「对方是全新设备，需由本机配对」或「本机需向对方索取密钥」。

> 实现说明：服务广播（注册）与监听（查询）由 `mdns_dart` 完成。
> 选型理由见 `README.md`「技术栈调整」一节。

---

## 2. 信封格式

所有消息统一为一个 JSON 对象：

```json
{
  "type": "note_push",
  "nonce": "<base64, 12 bytes>",
  "payload": "<base64, AES-GCM 密文>",
  "tag": "<base64, 16 bytes>"
}
```

| 字段 | 说明 |
| --- | --- |
| `type` | 明文消息类型，用于路由与日志。**不含任何敏感内容** |
| `nonce` | AES-GCM 的 IV，12 字节随机，每条消息都新生成 |
| `payload` | AES-GCM 密文（不含 tag） |
| `tag` | AES-GCM 认证标签，16 字节 |

**明文载荷的编码**：`payload` 解出的明文是 **JSON 的 UTF-8 字节**（不做二次 base64）。
理由：JSON 本身就是文本格式，UTF-8 是自明的编码；再加一层 base64 只会放大体积、
并在二进制图片分块（`data` 字段）时造成 33% 膨胀。

> **已知的元数据泄露**：`type` 保持明文（协议规定），因此同一局域网内的被动监听者
> 可以观察到消息类型与节奏，但无法获知笔记内容、标题、设备名等。这是协议既有设计，
> 实现遵守之。

---

## 3. 两种密钥与派生

| 用途 | 输入 | 盐 | 迭代 | 长度 | 生效范围 |
| --- | --- | --- | --- | --- | --- |
| 配对握手密钥 | 6 位配对码 | `notepad_pair_v1` | 100000 | 32B | **仅** `pair_request` / `pair_success` / `pair_fail` |
| 会话密钥 | masterKey | `notepad_session_v1` | 10000 | 32B | 认证后全部消息 |

- 派生算法：PBKDF2，PRF 为 `HMac(SHA256Digest(), 64)`。
- **配对码不得作为长期通信密钥**：握手三条消息之后立即切换到会话密钥。

### 3.1 实现细节的固定项

需求文档未明确规定、由本实现固定并在此登记的细节：

1. **TOTP 密钥派生**：`totpSecret = PBKDF2(masterKey, salt="notepad_totp_v1", iter=10000, dkLen=32)`。
   需求文档规定配对码用 HMAC-SHA1 且兼容 RFC 6238，但未指明 TOTP 密钥从何而来。
   本实现选择**由 masterKey 确定性派生**，好处是：
   - 两台设备只要持有同一个 masterKey，就能各自算出相同的 TOTP 码，无需额外交换密钥；
   - masterKey 重置后配对码自动失效，符合「重置配对」的语义。
2. **masterKey 参与 PBKDF2 的字节形式**：使用其 **base64url 字符串的 UTF-8 字节**
   （而不是解码后的 16 字节原始值）。理由：两端拿到的字符串完全一致，
   不依赖解码细节（填充、字符集），排除一整类「两端派生出不同密钥」的实现分歧。
3. **时间戳格式**：所有时间戳为 **UTC ISO-8601**（如 `2026-11-12T00:00:00.000Z`）。
4. **配对码位数**：6 位十进制；步长 30s；校验窗口 ±1 步（±30s）。

---

## 4. 握手流程

### 4.0 配对请求使用 HMAC 证明（最终版，修掉循环依赖）

**第一版的缺陷**：`pair_request` 的载荷含 `code`，同时要求用
`PBKDF2(code, salt="notepad_pair_v1", iter=100000)` 加密该消息 ——
服务端解密前不知道 `code`，构成循环依赖，无法实现。

**最终版**：`pair_request` **明文**发送，不含任何机密，用 HMAC 证明持有配对码。

```json
{
  "type": "pair_request",
  "clientTime": 1712345678000,
  "nonce": "<base64 16B>",
  "deviceId": "<uuid>",
  "deviceName": "B的手机",
  "hmac": "<base64 HMAC-SHA256(PBKDF2(code,salt='notepad_pair_v1',iter=100000,len=32), 'clientTime|nonce|deviceId|deviceName')>"
}
```

**关键性质**

| 性质 | 说明 |
| --- | --- |
| `code` 不出现在载荷 | 明文码从不上线，嗅探 WS 流量看不到任何 6 位码 |
| HMAC 输入 | `"${clientTime}|${nonce}|${deviceId}|${deviceName}"`（原文，UTF-8） |
| 校验方式 | 服务端遍历当前时间 **±1 窗口的 3 个候选码**，逐个算 HMAC，**恒定时间比较** |
| 重放拒绝 | `nonce` 为 16 字节随机；服务端缓存 **60s**，同一 nonce 只接受一次 |
| 失败处理 | 明文 `{type:"pair_fail", reason}`，**关闭连接**，同 deviceId 3 次锁 60s |
| 成功响应 | 用**命中 code** 的 PBKDF2 派生密钥加密 masterKey，AES-GCM 信封 `{nonce, payload, tag}` |

**为什么 HMAC 输入要包含 nonce 与 deviceId**

- `nonce`：使每条请求唯一，让 60s 缓存能有效拒绝重放；
- `deviceId` / `deviceName`：把证明绑定到具体设备，防止换设备重放同一条请求。

**恒定时间比较（约束项）**：所有 HMAC / tag 比较必须走
`Hashing.constantTimeEquals`（逐字节异或累积，长度不同才提前返回），
不得使用 `==` 或 `ListEquality`，避免时序侧信道。

**为什么不需要先解密**：信封的 `type` 字段是明文，服务端据此区分
`pair_request`（HMAC 路径）与 `fast_auth`（会话密钥路径），因此不存在
「要先解密才知道这是什么消息」的问题。

### 4.1 首次配对（设备 B 尚无 masterKey）

```
设备 A（已有 masterKey，显示配对码）        设备 B（全新）
         │                                        │
         │◀──── pair_request（明文）──────────────│  clientTime, nonce, deviceId,
         │                                        │  deviceName, hmac
         │  遍历 ±1 窗口的 3 个候选码              │  （不含 code，见 4.0）
         │  逐个算 HMAC + 恒定时间比较             │
         │  ├─ 命中 ─▶ pair_success（AES-GCM）───▶│  masterKey
         │  │           用命中 code 派生密钥加密    │  解密后存 secure_storage
         │  │                                      │  切换到会话密钥
         │  └─ 未命中 ─▶ pair_fail（明文）────────▶│  reason
         │                 然后**立即关闭连接**      │
```

- 失败锁定：同一 IP/deviceId 在 60s 内累计 3 次失败后锁定 60s。
- 配对码仍是 6 位 TOTP（HMAC-SHA1、30s 步长、±1 容错），
  但**只作为 HMAC 与密钥派生的输入**，从不出现在消息里。
### 4.2 已配对设备重连

```
设备 B ──── fast_auth ────▶ 设备 A        payload: { deviceId }
           [会话密钥加密]
      A 尝试用会话密钥解密：
        ├─ 成功 ──▶ auth_ok ──────────────▶ B    payload: { serverDeviceId }
        │             然后进入同步          │
        └─ 失败 ──▶ 断开连接（提示重新配对）  │
```

**「能否成功解密」本身就是认证**：只有持有同一 masterKey 的设备才能派生出相同会话密钥。
GCM 的认证标签保证了这一点是密码学意义上的，而不是靠比较字符串。

---

## 5. 消息清单

| type | 方向 | 载荷字段 | 说明 |
| --- | --- | --- | --- |
| `pair_request` | B→A | `code`, `clientTime`, `deviceId`, `deviceName` | 首次配对请求 |
| `pair_success` | A→B | `masterKey` | 回传主密钥 |
| `pair_fail` | A→B | `reason` | 失败，随后关闭连接 |
| `fast_auth` | B→A | `deviceId` | 已配对设备重连 |
| `auth_ok` | A→B | `serverDeviceId` | 认证通过 |
| `note_summary` | 双向 | `notes: [{noteId, versionVector, contentHash, updatedAt, isDeleted, title}]` | 连接后交换摘要（**不含正文**） |
| `note_patch` | 双向 | `noteId, fromVersionVector, toVersionVector, patch, imageHashes` | 增量同步 |
| `note_patch_ack` | 双向 | `noteId` | patch 应用成功 |
| `note_patch_nack` | 双向 | `noteId, reason` | 版本不匹配，降级全量 |
| `note_chunk_manifest` | 双向 | `noteId, chunkHashes: []` | 大文件（≥256KB）块哈希清单 |
| `note_chunk_request` | 双向 | `noteId, chunkHashes: []` | 请求缺失块 |
| `note_chunk_push` | 双向 | `noteId, chunkHash, data` | 推送单个块 |
| `note_pull` | 双向 | `noteId` | 请求正文 |
| `note_push` | 双向 | `noteId`, `content`, **`versionVector`**, **`contentHash`**, `updatedAt`, `imageHashes`, `title` | 推送正文 |
| `note_delete` | 双向 | `noteId`, **`versionVector`** | 删除笔记（软删 + 版本向量） |
| `image_manifest` | 双向 | `hashes: []` | 图片哈希清单 |
| `image_request` | 双向 | `hashes: []` | 请求缺失图片 |
| `image_chunk` | 双向 | `hash`, `seq`, `total`, `data` | 分块传输，每块 ≤128KB |
| `image_complete` | 双向 | `hash`, `sha256` | 传输完成校验 |
| `ping` / `pong` | 双向 | `ts` | 心跳，30s 间隔 |

- `data` 字段是**二进制分块的 base64**（JSON 无法承载裸二进制）。单块 ≤128KB，
  编码后约 170KB，在 WS 单帧与默认内存阈值内。
- `note_pull` 的响应复用 `note_push`（同一载荷结构），减少消息类型。

---

## 6. 同步算法（最终版：版本向量 + patch + 冲突副本）

### 6.1 版本字段：int → 版本向量

| 项目 | 第一版 | 最终版 |
| --- | --- | --- |
| 版本字段 | `Note.version: int` | `versionVector: Map<deviceId, int>`（JSON 存 TEXT） |
| 冲突判定 | `updatedAt` LWW | 版本向量比较：equal / dominates / dominated / concurrent |
| 分叉处理 | 直接覆盖 | **冲突副本**（两份都保留） |

### 6.2 版本向量比较

逐设备比较计数（缺席视为 0）：

| 关系 | 条件 | 动作 |
| --- | --- | --- |
| `equal` | 所有设备计数相同 | 再用 `contentHash` 确认；相同则跳过 |
| `dominates` | 本地各项 ≥ 对端，且至少一项 > | 本地更新 → 推送（patch / 全量 / 块级） |
| `dominated` | 本地各项 ≤ 对端，且至少一项 < | 对端更新 → `note_pull` |
| `concurrent` | 互不支配 | **生成冲突副本**，两份都保留 |

### 6.3 连接后同步流程

```
auth_ok
   │
   ├─ 双方各发 note_summary（不含正文）
   │
   ├─ 逐篇按版本向量分类：
   │    · equal 且 contentHash 相同          → 跳过
   │    · dominated                          → note_pull 全量
   │    · dominates 且对端未动（基线版本 == 对端版本）
   │        且 <256KB                         → note_patch；nack 则降级 note_push
   │    · dominates 且 ≥256KB                 → 块级差异同步
   │          (note_chunk_manifest → request → push)
   │    · concurrent                          → 冲突副本
   │
   ├─ 图片同步：image_manifest 对比（第一版逻辑不变）
   │
   └─ patch 失败 / 版本跳变 → 全量降级，用 updatedAt LWW 兜底
```

### 6.4 增量 patch 约束

- 编辑防抖 **500ms** + 节流 **2s**；
- `baseText` 从 `sync_baselines.base_text` 读（**不再从文件读**）；
- `newText` 从 `notes.content` 读；
- **离线期间的多次编辑不生成多个 patch**：重连时用
  `PatchUtil.makePatch(基线文本, 当前文本)` 生成**单个**合并 patch，
  体积只与「文本差异量」有关，与编辑次数无关；
- patch 体积 > 全量 70% → 直接 `note_push`；
- UTF-16 代理对检测失败 → 放弃 patch，改走全量。

> **patch 何时可用**：仅当「基线版本 == 对端版本」，即对端自上次同步后确实没动过。
> 此时基线正文就是双方的共同祖先，patch 必然能干净应用。
> 缺少基线记录时保守走全量（不做猜测）。

**实现说明**：`PatchUtil` 是自行实现的**行级 LCS diff**（`packages/notepad_core/lib/src/sync/patch_util.dart`）。
不用 `diff_match_patch` 是因为它最新版 0.4.1（2021）的 SDK 约束是 `<3.0.0`，不支持 Dart 3。
patch 格式自带基线校验：`applyPatch` 在基线不匹配时**返回 null**（而非静默产出错文本），
便于上层降级为全量。

### 6.5 冲突副本规则

分叉时（`concurrent`）：

1. 按 `updatedAt` 判定胜者；**时间相同**则按 `contentHash` 字典序打破平局
   （保证两端各自计算得到同一个胜者）；
2. **胜者保留原 noteId**；
3. **败者分配新 noteId**，标题追加后缀 `（冲突副本）`；
4. **只有败者一方写入副本**，然后把「副本 + 收敛后的原 id 记录」一起推给胜者一方
   —— 这样两端最终都有两份，且**不会因两端各写副本导致副本重传/爆炸**；
5. 版本向量取逐项最大值合并，使两端收敛。

**两份内容都必须保留** —— 这是硬约束，不允许直接覆盖。

### 6.6 块级差异同步（≥256KB）

- 分块大小 **64KB**；
- 块哈希 = `SHA-256(块字节)`；
- 接收端先按 `note_chunk_manifest` 算出「本地已有的块」，只请求缺失块
  （`note_chunk_request`），发送端用 `note_chunk_push` 逐一推送；
- 全部块就位后用整篇 `contentHash` 做二次校验。

### 6.7 握手期的重放防护

| 消息 | 防护 |
| --- | --- |
| `pair_request` | `nonce` 16 字节随机，服务端缓存 **60s**（`TtlNonceCache`），同一 nonce 只接受一次 |
| `fast_auth` | 信封 `nonce` 亦经 60s 去重（`TtlNonceCache`），重放直接断开 |
| 认证后所有消息 | `SecureSession` 内部 `NonceCache`（最近 200 条） |


## 7. 安全要求与实现对照

| 要求 | 实现 |
| --- | --- |
| masterKey 只存 secure_storage | `flutter_secure_storage`，shared_preferences 里只出现引用/占位 |
| 密文篡改必须被发现 | AES-GCM 认证标签，失败即丢弃并断开 |
| 防重放 | 每条消息随机 nonce；接收端缓存最近 200 个 nonce，重复即丢弃 |
| 配对失败即断开 | 发 `pair_fail` 后立即 `close()` |
| 配对码不得长期用作密钥 | 仅握手三条消息用，之后切会话密钥 |
| 禁止明文日志泄漏密钥 | 日志只记录类型/长度/nonce 前 8 字节，不记录密钥与明文 |

**日志脱敏约定**：密钥、masterKey、配对码、笔记正文一律不进日志。
调试日志里出现的密文材料最多是 nonce 的前 8 字节（用于定位重放问题）。

---

## 8. 版本演进

- 协议版本通过 `_notepad._tcp` 的 TXT 增加 `v=2` 字段表达。
- **v1 → v2 不兼容**：`pair_request` 由「加密载荷含 code」改为「明文 + HMAC」（§4.0）；
  同步由 updatedAt LWW 改为版本向量 + patch + 冲突副本（§6.1）。旧版客户端握手会失败并断开，
  需双方升级后重新配对。

---

## 9. 实现层面的设计决策（由实现确定，在此登记）

需求文档给了消息类型与阈值，但未规定部分细节。以下是本项目固定下来的实现决策，
后续维护者改动时需同步更新本节。

### 9.1 `pair_fail` 为明文，且携带原因

`pair_request` 改为明文 + HMAC 后（§4.0），失败响应也按文档规定用明文
`{type:"pair_fail", reason}`。这**确实**让未认证的连接能看到失败原因字符串。

采取的两点收敛措施：

- **格式错误与重放不计入失败次数** —— 否则攻击者可以用廉价的伪造包把正常设备锁死 60s；
- 失败后**立即关闭连接**，不提供重试机会。

可接受的失败原因集合（不外泄更多信息）：

| reason | 触发条件 |
| --- | --- |
| `配对码错误` | HMAC 与 ±1 窗口内 3 个候选码都不匹配 |
| `重复的配对请求` | 同一 nonce 在 60s 内二次出现 |
| `设备时间偏差过大` | `clientTime` 与本机偏差 > 60s |
| `失败次数过多，请 N 秒后重试` | 同 IP/deviceId 60s 内失败 3 次 |

> 若要进一步收紧，可改为「只发 `pair_fail` 不带原因」。当前保留原因是为了
> 让用户能区分「码输错了」与「手机时间不对」——这是排障必需的信息，
> 且不泄漏任何可用于爆破的比特。

### 9.2 块级差异同步的分块参数

- 分块大小 **64KB**（比图片分块的 128KB 小，因为笔记正文的中文密度高，
  小块能让「只改几行」的场景命中更多已有块）；
- 块哈希 = `SHA-256(块字节)`，清单只发哈希列表（不发数据）；
- 接收端算出「本地已有块 → 只请求缺失块」；
- 全部块就位后用整篇 `contentHash` 做二次校验（防拼接错误）。

### 9.3 冲突副本的收敛责任

`SyncPlanner.resolveConflict` 只给出 winner/loser，**未规定两端各该写什么**。
本项目采用：

**只有败者一方调用 `saveConflictCopy` 写入副本**，然后把「副本 + 收敛后的原 id 记录」
一起推给胜者一方。

理由：如果两端都各自生成副本，会得到**两个 id 不同、内容相同**的副本，
它们在下一轮同步中又会被判定为「对端缺失」而互相推送，导致**副本爆炸**。
由败者单独负责写入，可保证两端最终都有两份且不重复。

### 9.4 `note_summary` 不携带 `createdAt`

摘要只用于判断「是否需要同步」，因此不带 `createdAt`。
`NoteMeta.fromSummary()` 还原时用 `updatedAt` 作占位 ——
**该值不是真实创建时间**，仅供排序/比较使用。
真正的 `createdAt` 由本地库保留（`writeFromPeer` 会保留本地已有的值），
因此同步不会污染创建时间。需要展示创建时间时必须读本地库。
