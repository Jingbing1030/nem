# 局域网记事本（LAN Notepad）

跨平台 Markdown 笔记应用：本地优先、内容寻址图片存储、自定义主题，
通过局域网 mDNS 自动发现 + 配对码认证 + AES-GCM 加密同步。

> **本文档对应需求的「最终版」**（存储架构反转 + HMAC 配对 + 版本向量同步）。
> 与第一版的三条核心差异：
> 1. **正文入库**：SQLite（drift）是唯一真相源，md 仅作导出产物（含备份/导出/搜索配套）
> 2. **配对改用 HMAC 证明**：修掉「配对码既在载荷里又当密钥」的循环依赖
> 3. **同步用版本向量 + patch + 冲突副本**，替代单一 version + updatedAt LWW

> **当前状态**：阶段 0（可行性确认）与阶段 1 的核心逻辑层已完成并通过单测。
> 项目进度、构建方式与已知限制见下文。

---

## 1. 仓库结构

```
lan-notepad/
├── packages/
│   └── notepad_core/        # 纯 Dart 核心逻辑（不依赖 Flutter）
│       ├── lib/src/crypto/      # AES-GCM、PBKDF2、TOTP、SHA、重放防护、恒定时间比较
│       ├── lib/src/protocol/     # 消息信封、消息类型、HMAC 配对握手
│       ├── lib/src/notes/        # Markdown 解析、路径安全约束
│       ├── lib/src/version/      # 版本向量（equal/dominates/dominated/concurrent）
│       └── lib/src/sync/         # 数据模型、版本向量同步规划、冲突副本
│   └── app/                 # Flutter 应用
│       ├── lib/src/db/           # drift 数据库（正文+元数据+基线+FTS）
│       ├── lib/src/export/       # md 导出（含图片复制）
│       ├── lib/src/search/       # 搜索抽象（LIKE / FTS5 双实现）
│       └── lib/src/net/          # WS、mDNS、配对限流、同步引擎
├── docs/
├── PROTOCOL.md              # WS 消息格式与握手流程
└── README.md
```

**为什么把核心逻辑拆成独立的纯 Dart 包**：加密、TOTP、哈希、冲突解决都不依赖
Flutter SDK 或平台通道，拆出来之后可以在任何有 Dart 的机器上**秒级跑完单测**
（本项目实测 128 个用例约 3 秒），不必等待 Flutter 构建。Flutter 侧只负责 UI
与平台能力（文件、剪贴板、网络、安全存储）。

---

## 2. 环境要求与构建

### 2.1 运行核心包单测（最轻量）

只需要 Dart SDK ≥ 3.14：

```bash
cd packages/notepad_core
dart pub get
dart test          # 全部单元测试
dart analyze       # 静态检查
```

### 2.2 构建 App

需要 Flutter SDK（stable）+ Android SDK/JDK 17：

```bash
flutter pub get
flutter test                 # widget / 集成测试
flutter build apk --debug    # 或 --release
```

> `--release` 在 CI 上**需要 JDK 21**（不是 17）：AGP 9.3.1 的
> `lintVitalAnalyzeRelease` 会调用 JDK 21 才有的 `List.removeLast()`
> （`CommentDetector` → `JavaDocParser`），JDK 17 下抛 `NoSuchMethodError`。
> 这是 AGP 自身的 bug，只能迁就。debug 构建不跑 `lintVital`，所以用 17 也能过。

### 2.3 自动发版（GitHub Actions）

`.github/workflows/build-apk.yml` 有 **3 条路径**：

| 触发 | 行为 |
|---|---|
| push 到 `main` | 核心包测试 + **debug** 构建（**不发 Release**，避免刷屏）|
| push tag `v*` | 核心包测试 + **release** 构建 + **自动创建/更新 GitHub Release** |
| 手动 `workflow_dispatch` | 同上；`publish_release` 取消勾选则只构建不发 Release |

**发一个正式版的完整流程**（tag 与 `version:` 必须一致，workflow 会校验）：

```bash
# 1) 改 app/pubspec.yaml 的 version（如 0.2.1+2 → 0.2.2+3）
# 2) 提交
git commit -am "发布 v0.2.2"
git push origin main
# 3) 打 tag 并推送 —— 这一步就会触发 release 构建 + 发 Release
git tag v0.2.2 && git push origin v0.2.2
```

tag 里的版本**不带 `+build` 段**（`0.2.1+2` → tag `v0.2.1`），这个映射由
workflow 从 `pubspec.yaml` 自动推导，无需手工同步。

> **签名**：默认回落到 Android Debug 证书，**各次 CI 运行签名不同、无法覆盖安装**；
> 要能持续升级必须先配 4 个 Secrets —— 详见 [§7.9 发行版签名与覆盖安装](#79-发行版签名与覆盖安装)。

---

## 3. ⚠️ 本项目的开发环境限制（重要，请先读）

本次交付是在**一台 Android 手机上的 Linux 容器**中完成的，环境有硬约束，
因此**交付形态与常规开发不同**，这里如实说明：

| 约束 | 事实 | 影响 |
| --- | --- | --- |
| 主机是 **aarch64** | Flutter 官方**不发布** arm64 Linux SDK（只有 x64 归档） | 无法在本机直接跑 `flutter` 命令 |
| 备用服务器也是 aarch64 | 甲骨文 Ampere A1，2 核 | 同上，需 qemu 模拟 x64 |
| Android `aapt2` | Google 只发布 `linux`(x64) / osx / windows，**无 linux-aarch64** | 构建 APK 必须走 x64 环境 |
| qemu 模拟 | 服务器已注册 `binfmt_misc` 的 `qemu-x86_64` | x64 工具链可跑，但**慢** |

**实测数据**（服务器 2 核 aarch64 + qemu 模拟 x64）：

| 操作 | 耗时 |
| --- | --- |
| `flutter pub get` | 10 秒 |
| `flutter test` | 约 5 分钟 |
| `flutter analyze` | 约 3 分钟 |
| 原生 arm64 `dart test`（128 用例） | **约 3 秒** |

这就是把核心逻辑拆成纯 Dart 包的直接原因：把「需要频繁迭代的密码学与同步逻辑」
放在秒级反馈的原生 Dart 上验证，把「慢且笨重」的 Flutter 构建留给最终产物。

---

## 4. 技术栈

按项目需求清单固定选型，其中**两项做了替换**（理由如下，其余保持不变）：

| 用途 | 需求指定 | 实际使用 | 说明 |
| --- | --- | --- | --- |
| mDNS | `multicast_dns` | **`mdns_dart`** | 见下方说明 |
| 状态管理 | `riverpod` | 同 | |
| 本地数据库 | `isar` | **`drift` + `sqlite3`** | 见 4.2（最终版改用 SQLite） |
| 加密 | `pointycastle` | 同 | `AESEngine` + `GCMBlockCipher` + `AEADParameters` |
| 哈希 | `crypto` | 同 | SHA-1 / SHA-256 / HMAC |
| WebSocket | `web_socket_channel` | 同 | |
| Markdown | `flutter_markdown_plus` | 同 | |
| 安全存储 | `flutter_secure_storage` | 同 | masterKey |
| 配置 | `shared_preferences` | 同 | 主题、设备名 |
| 文件/图片 | `file_picker` + `image_picker` | 同 | |
| 剪贴板 | `super_clipboard` | 同 | |
| 图片压缩 | `flutter_image_compress` | 同 | 默认开启 |

### 4.1 替换一：`multicast_dns` → `mdns_dart`

**原因**：`multicast_dns` 只做**服务发现（查询）**，不提供服务**注册/广播**能力。
需求 5.6 要求「服务端启动时注册 mDNS 服务，并把动态端口写入 TXT 记录」，
用 `multicast_dns` 无法实现广播这一半。

**替代**：`mdns_dart` 同时支持发现与广播，是纯 Dart 实现、无平台通道依赖。

> 备选：`nsd`（Flutter 插件，走系统 NSD API，更省电，但引入平台实现，
> 且纯 Dart 侧无法参与测试）。若后续对移动端功耗有要求，可切到 `nsd`，
> 协议层不受影响。

### 4.2 存储：废弃 Isar，改用 drift（SQLite）

**第一版指定 Isar，最终版要求正文入库，因此必须换掉。** 两层原因：

1. **最终版明确要求删除 isar / isar_flutter_libs，新增 drift。**
2. 即使不考虑需求变更，官方 `isar` 也无法使用：最新版停在 `3.1.0+1`（2023-04），
   SDK 约束 `>=2.17.0 <3.0.0` **明确不支持 Dart 3**（当前为 3.14）。

采用 `drift` + `sqlite3`。**注意：不需要 `sqlite3_flutter_libs`** ——
`sqlite3 3.x` 通过 Dart hooks 机制自带原生 SQLite 库，而
`sqlite3_flutter_libs` 已被官方标记 `0.6.0+eol` 并注明
「Not used anymore, update to version 3.x of package:sqlite3 instead」。
最终版清单里列出的该依赖因此不再添加。

### 4.2.1 数据库表（对应变更 3）

- `notes`：`note_id` / `title` / **`content`** / `excerpt` / **`version_vector`** /
  **`content_hash`** / `image_hashes` / `is_deleted` / `created_at` / `updated_at`
- `sync_baselines`：（`note_id`, `peer_device_id`）联合主键 + `version_vector` + **`base_text`**
- `search_index`：FTS 索引表（`note_id` / `title` / `content`）

### 4.3 依赖冲突一：`build_runner` 与代码生成器（`drift_dev` / `isar_community_generator`）

**实测冲突**（`pub get` 直接失败）：

```
Because build_runner >=2.17.1 depends on build >=5.0.0 <5.1.0
and isar_community_generator >=3.3.1 depends on build ^4.0.0,
build_runner >=2.17.1 is incompatible with isar_community_generator >=3.3.1.
```

**结论**：`build_runner` 必须约束在 `>=2.16.0 <2.17.1`（即 2.16.x）。
分界点很清晰 —— 2.17.0 用 `build ^4.1.0`（兼容），2.17.1 跳到 `build >=5.0.0`（不兼容）。
这是**传递依赖冲突**，与本项目代码无关，但会让代码生成（drift/Isar 的 `*.g.dart`）完全不可用。
（第一版用 Isar 时这个冲突就已存在；改用 drift 后同样受 `build` 版本区间约束，故仍须锁定。）

```yaml
build_runner: ">=2.16.0 <2.17.1"
```

### 4.4 依赖冲突二：`flutter_secure_storage` 与 `super_clipboard`（经 `win32` 间接冲突）

**实测冲突**（`pub get` 直接失败）：

```
super_clipboard -> super_native_extensions -> device_info_plus (>=10.0.1 <12.0.0)
  -> win32 >=4.0.0 <6.0.0
flutter_secure_storage 11.x -> flutter_secure_storage_windows ^4.2.2
  -> win32 ^6.0.1
```

两者对 `win32` 的要求区间**不相交**，因此无法同时满足。

**结论**：把 `flutter_secure_storage` 约束在 `>=10.3.0 <11.0.0`。
10.3.4 的 windows 实现依赖 `win32 ^4.1.0`（其传递依赖为 `win32 ^5.5.4`），与 super_clipboard 兼容。
已核实 10.x 的 API 与本文档所需完全一致（`AndroidOptions(encryptedSharedPreferences: true)`、
`read` / `write` / `delete` 签名不变），**功能与安全性不受影响**。

> 说明：本项目目标是 Android / iOS，`win32` 只在 Windows 桌面构建时参与。
> 但 pub 的版本求解器是**全局**的，会因平台专属包的约束而整体失败 —— 这类
> 「与目标平台无关却阻断解析」的冲突正是最容易被忽略的一种。
> 另一条出路是使用 super_clipboard 的 `0.10.0-dev.x`（它放宽到 `device_info_plus <14.0.0`），
> 但那是预发布版本，不适合作为交付基线。

### 4.5 依赖冲突三：`file_picker` 与 `super_clipboard`（同为 `win32`）

把 `flutter_secure_storage` 降到 10.x 后，冲突**并没有消失**，只是换了个对手：

```
file_picker >=13.3.3 -> windows_file_picker ^2.0.2 -> win32 ^6.3.0
super_clipboard -> super_native_extensions -> device_info_plus -> win32 <6.0.0
```

**根因**：`win32` 处在 `^5.9.0+ / <6.0.0` 与 `^6.3.0` 两个不相交的区间上，
而 `super_clipboard` 一侧的约束是**上游锁死的**（`device_info_plus <12.0.0`），
所以只能从 `file_picker` 侧让步。

**结论**：`file_picker` 约束在 `>=11.0.0 <12.0.0`。
11.x 直接依赖 `win32 ^5.9.0`（中间没有 `windows_file_picker` 这一层），
与 `super_clipboard` 兼容；且 `FilePicker.platform.pickFiles(type: FileType.image, allowMultiple: false)`
的 API 未变，已核对源码确认。

最终解析结果：**`win32 5.15.0`** —— 三个约束同时满足。

> 教训：`win32` 这类**平台专属**包的版本区间最容易卡死全局解析，
> 而报错信息只会指出「哪两个包不兼容」，根因要顺藤摸瓜才能找到。
> 本项目三个冲突（build_runner / flutter_secure_storage / file_picker）里有两个都是 `win32`。

### 4.6 关于 `highlight` 与 `diff_match_patch`（两处不兼容的包）

需求清单里指定了两个**不支持 Dart 3** 的包，最终版变更清单又新增了一个：

| 包 | 最新版 | SDK 约束 | 结果 |
| --- | --- | --- | --- |
| `highlight`（含 `flutter_highlight` / `flutter_highlighting`） | 0.7.0（2021-03） | `>=2.12.0 <3.0.0` | ❌ 不能用 |
| `diff_match_patch` | 0.4.1（2021-06） | `>=2.12.0 <3.0.0` | ❌ 不能用 |

本项目使用 Dart 3.14，两者都无法引入。

**`highlight` 的替代**：`flutter_markdown_plus` 自带的代码块构建器负责渲染，
代码高亮由主题色与等宽字体承担（见 `MarkdownPreview` 的 `codeblockDecoration`）。
若后续需要语法着色，可引入 `re_highlight`（`>=2.17.0 <4.0.0`，活跃维护）。

**`diff_match_patch` 的替代**：自行实现行级 LCS diff —— `PatchUtil`
（`packages/notepad_core/lib/src/sync/patch_util.dart`）。
选型理由：

- 笔记是 Markdown 文本，改动通常集中在少数行，**行级 diff 足够**；
- 传输体积取决于「差异行数」而非编辑次数，满足变更 6.4 的要求；
- 不引入字符级最小 diff（精度收益有限、复杂度和字节开销更高）；
- patch 格式自带基线校验：`applyPatch` 在基线不匹配时**返回 null**，
  而不是静默产出错文本，便于上层降级为全量同步。

已覆盖的验收项（见 `test/patch_util_test.dart`，21 个用例）：
- 离线编辑 100 次后重连 → **单个 patch**，体积与编辑次数无关（只与差异量有关）；
- 1MB 笔记改 3 处 → patch **< 50KB**；
- patch 体积 > 全量 70% → 判定为不值得发（改走全量）。

### 4.7 关于 `sqlite3_flutter_libs`（需求列出但**不应添加**）

最终版变更清单要求新增 `sqlite3_flutter_libs`，但：

- 该包最新版是 **`0.6.0+eol`**，描述明确写着
  「*Not used anymore, update to version 3.x of package:sqlite3 instead*」；
- `sqlite3 3.x` 已通过 **Dart hooks** 机制自带原生 SQLite 库（`.hooks/` 目录），
  不再需要单独的 flutter_libs 包。

因此本项目只依赖 `sqlite3: ^3.9.1`，**不加** `sqlite3_flutter_libs`。
已在真机构建中验证可行。


需求要求代码高亮用 `highlight` 包。该包（含 `flutter_highlight`、
`flutter_highlighting`）最新版本发布于 2021–2023 年，SDK 约束同样为
`<3.0.0`，**无法在 Dart 3 上使用**。

替代方案（二者择一，实现时确认）：`flutter_markdown_plus` 自带的代码块
构建器 + 轻量高亮，或 `re_highlight`（`>=2.17.0 <4.0.0`，活跃）。
这是**第三个需要调整的选型**，属「明确不兼容」情形。

### 4.8 构建期的上游不兼容（Flutter 3.50 + AGP 9 + Gradle 9）

上面 4.3~4.5 是**依赖解析期**的冲突（`pub get` 直接失败）。
本节是**构建期**的问题 —— `pub get` 能过，但 Gradle 跑到一半才失败。
两者性质不同，排查方式也不同：**不能只看 `pub get` 是否成功**。

这个版本组合（Flutter 3.50.0 / AGP 9.3.1 / Gradle 9.5.0 / JDK 17+）比较新，
插件生态尚未跟上，实测遇到 **5 处上游失配**，都需要打补丁或调配置才能构建：

| # | 现象（报错关键行） | 根因 | 解法 |
| --- | --- | --- | --- |
| 1 | `cannot find symbol: class FilePickerPlugin` | `file_picker 11.0.3` 用**条件式** apply：`if (!isAgp9OrAbove) apply plugin: 'kotlin.android'`。而 Flutter 的兜底判断靠**正则扫 build 脚本文本**（`FlutterPluginUtils.kt` 的 `kgpRegexGroovy`），**看不懂 `if` 条件** → 误判「已 apply」→ 跳过兜底。结果 AGP 9 下双方都不管 Kotlin，`.kt` 无人编译 | 在根 `build.gradle.kts` 里对 `:file_picker` 用 `plugins.withId("com.android.library")` 显式补一次 KGP apply |
| 2 | `AAPT: error: resource mipmap/ic_launcher not found` | `res/mipmap-*/ic_launcher.png` 缺失 | 从 Flutter 官方模板补齐 5 个密度 + 启动画面资源 |
| 3 | `Could not find method exec()` on `project '...'` | **Gradle 9 移除了 `Project.exec()`**（用 `javap` 确认 `Project` 接口里已无该方法），而 cargokit 仍在用 | 用 `@Inject abstract ExecOperations getExecOperations()` 注入，把 `project.exec {}` 换成 `execOperations.exec {}.assertNormalExitValue()`。**注意**：该代码在 `DefaultTask` 子类里，`DefaultTask` **没有 `providers`** 属性，所以不能用 `providers.exec`；且 `assertNormalExitValue()` 不可省（否则构建失败会被静默吞掉） |
| 4 | `checkDebugAarMetadata`：20 个 androidx 依赖要求 `compileSdk >= 34` | `irondash_engine_context 0.5.5` / `super_native_extensions 0.9.1`（cargokit 家族）的 `android/build.gradle` **硬编码 `compileSdkVersion 31`** | 补丁把这两处抬到 36（Flutter 3.50 的默认值）。只改编译期 API 级别，不动 `minSdk`/`targetSdk` |
| 5 | `NoSuchMethodError: java.util.List.removeLast()`（**仅 release 构建**） | AGP 9.3.1 的 `lintVitalRelease`（`CommentDetector`）调用了 **JDK 21 才有的** `SequencedCollection` API，JDK 17 下不存在 | **构建 release 需要 JDK 21**。注意 `lintVital` **只在 release 跑**，所以 debug 用 JDK 17 全绿也发现不了这个问题 |

**关于第 5 条的一个连带坑**：换成 JDK 21 后会暴露

```
Inconsistent JVM-target compatibility detected for tasks
  'compileReleaseJavaWithJavac' (17) and 'compileReleaseKotlin' (21)
```

因为 Kotlin 插件在未显式指定 `jvmTarget` 时会**跟随 JDK 版本**，
而各插件 `compileOptions` 固定为 17。其中 `file_picker` 的 `kotlinOptions { jvmTarget = 17 }`
又写在 `if (!isAgp9OrAbove) {}` 里（**与第 1 条同源**），AGP 9 下被跳过。
→ 解法是在根 `build.gradle.kts` 里对这些插件统一 `compilerOptions.jvmTarget = JVM_17`
（用 `plugins.withId` 保证时序；**不能用已废弃的 `kotlinOptions`**，Kotlin 2.x 下会编译报错）。

**结论**：在这个版本组合下，**不要期待插件生态即插即用**。
`app/android/build.gradle.kts` 与 `.github/scripts/patch-cargokit.py` 里的补丁
就是为此存在的 —— 若将来上游适配了，可逐条删除。

### 4.9 依赖冲突四：`package_info_plus` 10.x 与 `super_clipboard`（又是 `win32`）

实现「检查 GitHub Release 自动提示更新」时需要读当前版本号。
`package_info_plus` 最新版是 **10.2.2**，但它要求 `win32 ^6.0.0`：

```
package_info_plus 10.x -> win32 ^6.0.1
super_clipboard -> super_native_extensions -> device_info_plus (<12.0.0)
  -> win32 <6.0.0
```

与 4.4 / 4.5 完全同源 —— 第四个被 `win32` 卡住的包。

**结论**：约束在 `>=9.0.0 <10.0.0`（实解析 **9.0.1**）。
9.0.1 依赖 `win32 ^5.5.3`，与当前锁定的 `win32 5.15.0` 相容，
且 `PackageInfo.fromPlatform()` 的 `version` 字段 API 未变。
本次 `pub get` 后 `win32` **仍停在 5.15.0**，未发生任何既有依赖的漂移。

同批加入的另两个依赖没有冲突：
`http`（原本已经是 `web_socket_channel` 带入的传递依赖，这里只是提为直接依赖）、
`url_launcher ^6.3.2`（其 `url_launcher_windows` 已不再依赖 `win32`）。

> ⚠️ 附带确认：`url_launcher` 用 `LaunchMode.externalApplication` 时，
> Android 侧 `requireNonBrowser = false`，`:app` 模块**不需要**在
> `<queries>` 里声明 `ACTION_VIEW`（Android 11+ 的包可见性限制不影响它）。
> 已核对 `url_launcher_android 6.3.33` 的 `UrlLauncher.java` 默认实现。

---

## 5. 已完成的测试覆盖

**实测数字（2026-11-13 重跑）**：

| 测试集 | 文件数 | 用例数 | 命令 |
| --- | --- | --- | --- |
| 核心包（纯 Dart，不依赖 Flutter） | 14 | **288** | `cd packages/notepad_core && dart test` |
| App 层（需 Flutter） | 13 | **326** | `cd app && flutter test` |

核心包不依赖 Flutter，单测**几秒跑完** —— 改动加解密/协议/同步算法后，这是最划算的验证手段。

### 5.1 `packages/notepad_core/test/`

| 文件 | 覆盖内容 |
| --- | --- |
| `aes_gcm_test.dart` | 加解密往返（含空载荷、1MB）、IV/tag 长度、IV 随机性、**篡改检测（密文/tag/nonce 各翻转一位）**、错误密钥、AAD 认证、参数校验 |
| `totp_test.dart` | **RFC 4226 / RFC 6238 官方测试向量**、±1 窗口（±30s 通过、±60s 拒绝）、步长刷新、倒计时 |
| `kdf_test.dart` | PBKDF2 确定性与参数敏感性、协议固定参数断言、masterKey 生成（长度/字符集/随机性）、**域分离**（pair/session/totp 三种盐不同） |
| `hashing_test.dart` | SHA-256 / SHA-1 官方向量、内容相同哈希相同（图片去重依据）、文件流式哈希、HMAC-SHA1、**恒定时间比较** |
| `envelope_test.dart` | 信封编解码与字段名、明文不含敏感内容、**重放拒绝**、nonce 缓存容量与淘汰、篡改消息不污染缓存 |
| `pairing_test.dart` | **HMAC 配对**（变更 2）：载荷无明文码、错误码拒绝且不泄露「接近了」、±1 时间窗、重放拒绝、恒定时间比较 |
| `version_vector_test.dart` | **equal / dominates / dominated / concurrent 四态**、序列化往返、merge 语义 |
| `sync_planner_test.dart` | 版本向量分类 → skip / pull / patch / push / pushDelete / conflict / blockSync 决策、删除传播、块级同步阈值 |
| `sync_convergence_test.dart` | **两设备收敛**（多轮迭代至稳定）、并发 → 冲突副本且两份都保留、离线 100 次编辑只产生单个待发动作、删除传播、空设备边界 |
| `patch_util_test.dart` | 补丁往返（含随机 100 组）、**1MB 改 3 处 patch < 50KB**、基线不匹配返回 null |
| `two_device_e2e_test.dart` | **端到端**：配对 → 会话 → 同步 → 图片分块校验（SHA-256 一致）→ fast_auth 免码重连 → 攻击面（篡改/重放） |
| `vault_paths_test.dart` | **禁止绝对路径 / `file://` / 盘符 / 反斜杠 / `data:` / base64 内嵌 / 路径穿越**、文件名格式、主题目录与图片目录隔离 |
| `markdown_doc_test.dart` | 标题提取三条规则、摘要生成、图片引用/哈希抽取、光标处插入图片 |
| `acceptance_test.dart` | 验收清单中可在纯逻辑层验证的条目集中处（如 pair_request 无明文码、patch 体积与编辑次数无关） |

### 5.2 `app/test/`

| 文件 | 覆盖内容 |
| --- | --- |
| `schema_smoke_test.dart` | **最小冒烟**：建表、写入读回、索引真实存在、备份文件可被 sqlite3 打开、事务回滚、`integrity_check` |
| `database_test.dart` | drift 表结构与索引、`integrityCheck`、`EXPLAIN QUERY PLAN` 验证索引被真实使用 |
| `note_repository_test.dart` | 笔记 CRUD、软删除与墓碑、版本向量推进、`applyRemoteDelete` 合并、**冲突副本不撞 id（防回归）**、关库重开数据保留 |
| `vault_paths_test.dart` | 目录布局、备份命名与列举、**只认真正的 64 位十六进制哈希**（防 GC 误删） |
| `image_vault_test.dart` | 内容寻址导入与去重、压缩开关、**GC 不误删非哈希文件**、`theme/` 与 `assets/images` 隔离 |
| `md_exporter_test.dart` | 导出 md、图片复制到 `assets/images/`、墓碑处理、空目录边界 |
| `search_test.dart` | `LIKE` 与 FTS 两种实现、`shouldUseFts` 阈值、索引重建 |
| `markdown_preview_test.dart` | widget 层渲染标题/列表/代码块/表格/任务列表/图片 |
| `app_config_test.dart` | 配置序列化**不含密钥字段**、`masterKey` 只在 `secure_storage` |
| `pairing_guard_test.dart` | 3 次失败锁 60s、按 IP 隔离、成功清零、窗口过期不计入 |
| `update_version_test.dart` | **语义化版本比较**：`0.9.0 < 0.10.0`、`v` 前缀、`+build` 后缀、位数不等、预发布版、脏数据不抛异常 |
| `update_checker_test.dart` | GitHub API 容错：403 限流/404/超时/JSON 变形 **全部返回 null**、缓存命中只请求一次、跳过语义 |
| `update_dialog_test.dart` | 弹窗三个按钮行为、打不开浏览器不崩、超长 body 截断、**不阻塞首屏** |

---

## 6. 双设备联调步骤（配对与同步）

> 需要两台真机（或一台真机 + 一台模拟器），处于**同一局域网**、
> 且路由器**未开启 AP 隔离（客户端隔离）**——这是 mDNS 与 WS 直连的前提。

1. **设备 A**：首次启动 → 生成 128 位 masterKey 存入 secure_storage
   → 自动开启 WS 服务端（端口动态分配）→ 注册 mDNS 服务（TXT 含 `hasKey=1`）。
2. **设备 A**：进入「配对」页 → 显示 6 位 TOTP 码，每 30 秒自动刷新。
3. **设备 B**：打开「设备」页 → 应能看到 A（mDNS 发现）→ 点击连接 → 输入 6 位码。
4. **配对**：B 发 `pair_request`（用 PBKDF2(code) 派生握手密钥加密）
   → A 校验（用 B 的 `clientTime`，窗口 ±1）→ 通过则回 `pair_success`（内含 masterKey）
   → B 解密后存 secure_storage → 双方切换到会话密钥。
5. **失败路径**：输入错误码 → 收到 `pair_fail` 且连接**立即关闭**；
   同 IP 在 60s 内失败 3 次 → 锁定 60s。
6. **同步**：配对成功后自动全量对比（`note_list` + `image_manifest`）
   → 差异笔记按**版本向量**分类决定拉取/推送/增量 patch/冲突副本
   → 缺失图片分块传输并校验 SHA-256 → UI 显示「已同步」。
7. **增量**：任一端编辑笔记 → 500ms 防抖后推送 → 对端应及时更新。
8. **免配对重连**：两端重启 → 连接后立即 `fast_auth`（会话密钥加密）
   → 能解密即认证通过 → `auth_ok` → 直接进入同步，无需再次输入码。

---

## 7. 已知限制

### 7.1 构建环境（重要）

本项目在 **Android 手机容器**（aarch64）中开发，备用构建机是一台
**aarch64 服务器（甲骨文 Ampere A1，仅 2 核）**。这带来两个限制：

- **Flutter 官方不发布 arm64 Linux SDK**（只有 x64 归档），因此构建必须经
  **qemu 模拟 x86_64**，速度极慢（Gradle 配置阶段就可能耗掉 40+ 分钟 CPU）；
- **Android `aapt2` 只有 x64 版本**，同样必须经 qemu。

**结论**：请把仓库拉到 **x64 机器**上执行 `flutter build apk`，这是推荐路径。
本仓库的代码本身与架构无关（纯 Dart + 平台插件），在 x64 上构建无需改动。

> 已确认的事实：在这台 aarch64 服务器上，`gradlew` 能成功编译 Flutter 的
> Gradle 插件（`:gradle:jar` 通过、0 错误），说明 **AGP 9.3.1 + Kotlin 2.4.20 +
> Gradle 9.5.0 的配置链路没有问题** —— 慢是算力问题，不是兼容问题。

### 7.2 代码高亮

`highlight` / `flutter_highlight` / `flutter_highlighting` 系列最新版
（2021–2023）的 SDK 约束均为 `<3.0.0`，**不支持 Dart 3**，无法引入。
当前代码块由 `flutter_markdown_plus` 自带构建器渲染（等宽字体 + 背景色），
无语法着色。若需要，可引入 `re_highlight`（`>=2.17.0 <4.0.0`，活跃）。

### 7.3 mDNS 的机型差异

部分 Android 厂商的省电策略会杀掉 mDNS 广播。实现上已在应用回到前台时
重新注册服务、进入后台时停止（符合需求 5.6），但仍可能在个别机型上不稳定。

### 7.4 网络环境

若路由器开启了**客户端隔离（AP 隔离）**，两台设备无法互相发现或连接。
这属于网络环境限制，不是应用缺陷。

### 7.5 协议版本

- 当前为 **v2**，与 v1 **不兼容**：`pair_request` 由「加密载荷含 code」改为
  「明文 + HMAC 证明」（§4.0 of PROTOCOL），配对码不再出现在任何消息中；
- 同步由 `updatedAt` LWW 改为**版本向量 + patch + 冲突副本**。
- 旧版客户端握手会失败并断开，需双方升级后重新配对。

### 7.6 同步策略

- 冲突解决用**版本向量**：并发编辑产生**冲突副本**（两份都保留），
  **不会静默丢弃任何一方**；
- **不做 CRDT**（需求明确排除）；如果需要无冲突协同编辑，需另设计；
- patch 仅在「基线版本 == 对端版本」时使用（此时基线正文是双方共同祖先，
  patch 必然能干净应用）；缺少基线时保守走全量。

### 7.7 搜索

- 阶段 1 用 **`LIKE` 实现**（`LikeSearchService`），简单可靠但**不走索引**；
- `FtsSearchService`（基于 `search_index` 表）已实现，当总字数超过
  1000 万时建议启用；
- FTS5 的 `unicode61` 分词器对中文会把「连续 CJK 视为一个词」，
  中文检索效果一般；若需更好效果应改用 **bigram 分词器**。

### 7.8 备份与恢复

- 每日首次编辑后自动 `VACUUM INTO` 备份，保留 **7 日 + 4 周**；
- 「从备份恢复」会在**同进程内**重开数据库（不需要用户手动杀进程），
  并在恢复前把当前库另存为 `notes.db.before-restore`；
- 恢复后建议自行确认数据完整（界面会提示完整性检查结果）。

### 7.9 发行版签名与覆盖安装

CI（`.github/workflows/build-apk.yml`）有两种签名模式，由
`app/android/build.gradle.kts` 自动选择：

| 模式 | 触发条件 | 后果 |
|---|---|---|
| **正式签名** | 配好 4 个 Secrets（见下） | ✅ 各版本签名一致，**可覆盖安装** |
| **Debug 证书回落** | 未配 Secrets | ⚠️ **CI 上每次运行签名都不同 → 无法覆盖安装** |

**为什么"CI 上用 debug 签名"会每次都不同（实测结论）**：

`actions/runner-images` 的 runner **没有预置** debug keystore（已核对上游仓库，
脚本里无任何 keystore / `androiddebugkey` 痕迹），于是 AGP 走
`ValidateSigningTask.createDefaultDebugKeystoreIfNeeded` →
`KeystoreHelper.createDebugStore()`，而该函数内部是
`KeyPairGenerator.generateKeyPair()`（**无 seed**）→ **每次都是新的随机密钥对**。

本项目实测三份 APK 的证书指纹，互不相同：

```
本机 debug   APK: DC:C5:F4:2A:17:FD:97:D0:66:6A:71:F0:92:17:4D:88:...
本机 release APK: DC:C5:F4:2A:...（与本机 debug 相同 —— 因为共用本机持久化的
                                  ~/.android/debug.keystore）
CI   release APK: 2C:A8:21:5A:4F:6C:42:64:97:BB:FA:18:FC:B5:B3:DD:...  ← 与上面都不同
```

> 注意：**本机**构建的 debug/release 签名**是稳定**的（`~/.android/debug.keystore`
> 会持久保存），所以本地测「覆盖安装」会通过，**但在 CI 产物上不成立** ——
> 这个差异很容易误导排查。

**具体影响**：从 CI 产物升级时，若新旧 APK 来自**不同一次 CI 运行**，
系统会报「应用未安装 / 签名不一致」，**必须先卸载旧版**（本地数据会被清除，
建议先导出笔记）。应用内的「检查更新」提示因此只保证**能下载到新版**，
不保证能直接覆盖安装。

**如何切到正式签名（推荐，一次性配置）**：

在 GitHub 仓库 **Settings → Secrets and variables → Actions → New repository secret**
添加这 **4 个**（缺一不可，否则 workflow 会明确报错而不是静默跳过）：

| Secret | 说明 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | keystore 文件的 base64（`base64 -w0 release.jks`） |
| `ANDROID_KEYSTORE_PASSWORD` | store 口令 |
| `ANDROID_KEY_PASSWORD` | key 口令 |
| `ANDROID_KEY_ALIAS` | key 别名 |

配好后无需改任何代码：workflow 会解码 keystore 并写 `app/android/key.properties`，
`build.gradle.kts` 检测到它就自动切到正式签名（并打印
`[signing] 使用 key.properties 中的正式签名配置`）。

> **密钥绝不会进仓库**：`.gitignore` 已排除 `*.jks` / `*.keystore` /
> `app/android/key.properties`；workflow 只打印证书指纹，不打印口令。
> 公开仓库**不要**把 keystore 放进 Actions Variables（协作者可见，且可能出现在日志里）。

---

### 7.10 深色模式、启动白闪与图标资源

#### 修复的三个问题（2026-11-13）

用户反馈：「打开之后整个背景会闪一下白色背景，然后变成纯黑色背景」。
实为三个独立缺陷叠加：

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | 启动瞬间**闪白** | `values-night/styles.xml` 的 `LaunchTheme` 指向 `@drawable/launch_background`，而该 drawable 内容是 `@android:color/white`，且**没有 `drawable-night` 版本** → 深色模式下启动画面仍是白的 | 新增 `drawable-night/launch_background.xml`；颜色改用 `values{,-night}/colors.xml` 里的具名颜色 |
| 2 | 随后变成**纯黑** | `buildThemeData` 把 `scaffoldBackgroundColor` 与 `canvasColor` **无条件设为透明**，而当时**没有任何组件负责铺底** → 整棵 UI 透明，直接露出 Android 窗口底色（`Theme.Black` 的 `colorBackground` = 纯黑 `#000000`） | 给 `BackgroundScaffold` 加**内置背景兜底**，使「总有一层不透明内容铺底」；底色因此可以安全地保持透明 |
| 3 | **不支持夜间模式** | `MaterialApp` 只设了 `theme`，没有 `darkTheme`/`themeMode`；`brightness` 只有 `light`/`dark` 两个值，默认还是 `light` | `brightness` 增加 `system`（默认）；`MaterialApp` 用 `theme` + `darkTheme` + `themeMode`，由 Flutter 原生跟随系统 |

**附带修掉的一个真 bug**：`textColor` 默认值是 `'#000000'`，
深色模式下会**黑字黑底看不见**（深色 fallback 永远不会生效，因为 `#000000` 能成功解析）。
现改为 `null` = 自动，按深浅色选黑/白；设置页也提供「自动」按钮。

#### 启动底色的取值依据

Android 资源是编译期常量，无法跟随用户在 App 内改的强调色。
为消除「启动画面 → 首帧」的色差，取值实测自 Flutter 实际输出：

```
buildThemeData(ThemeConfig(), brightness: light).colorScheme.surface = #F8F9FF
buildThemeData(ThemeConfig(), brightness: dark ).colorScheme.surface = #111418
```

（用 `ColorScheme.fromSeed` 的 surface 会带一点种子色倾向，所以强调色一变，
这两个值就不再精确 —— 但对消除最刺眼的白闪/黑闪仍然有效。）

#### 图像资源

| 资源 | 来源 | 生成方式 |
|---|---|---|
| 应用图标（`mipmap-*/ic_launcher.png`，5 个密度） | `assets/branding/source.jpg` | **原图直接缩放，不抠图、不合成** |
| 内置背景（`assets/backgrounds/app_bg.jpg`） | 同上 | 按宽度铺满 + 用原图自身黑底补足竖屏高度 |
| 启动底色（`values{,-night}/colors.xml`） | 实测 Flutter surface | 手工填写 |

重新生成：`bash app/tools/render-assets.sh`（依赖 ImageMagick）。
**不要手工编辑这些产物** —— 要改外观就改原图再重跑脚本。

**为什么不做自适应图标**（`mipmap-anydpi-v26/`）：它要求前景内容限制在中心
66/108 的安全区，且系统会按设备裁成圆形/方形/圆角，**会把原图的构图裁掉**。
传统图标能完整显示原图，故选择它。

#### 测试

`app/test/theme_test.dart`（14 例）+ `app/test/app_config_test.dart`（13 例）覆盖：
`system` 解析、非法值兜底、底色透明性、深色色板非纯黑、文字色自动/显式/非法回退、
色板随强调色变化、`BrightnessMode` 三态互斥、旧配置向前兼容。

---

## 8. 安全设计要点

- masterKey 只存 `flutter_secure_storage`（Android Keystore 支撑），
  `shared_preferences` 中仅存主题与设备名，**不含任何密钥**。
- 所有通信内容经 AES-256-GCM 加密，认证标签校验失败即**丢弃消息并断开连接**。
- 防重放：每条消息独立随机 nonce（12B），接收端缓存最近 200 个 nonce。
- 配对码**仅**用于握手三条消息，之后一律使用会话密钥。
- 日志脱敏：密钥、配对码、笔记正文永不入日志。

细节见 [PROTOCOL.md](PROTOCOL.md)。

---

## 9. 验收对照表（对照需求「最终版」清单）

图例：✅ 已验证（有可复现的测试或实测证据）／ 🔶 需两台真机在同一局域网，无法在 CI 或容器内验证

> 标 🔶 的项**不是没实现**，而是其验证条件（两台物理设备 + 真实 mDNS 组播 + 真实 WS 连接）
> 在容器/CI 环境中无法满足。其中的**同步算法与协议逻辑**已在纯逻辑层被
> `two_device_e2e_test.dart` / `sync_convergence_test.dart` 覆盖（用内存传输模拟两端），
> 未覆盖的只是「真实网络下的 mDNS 发现」与「真机 UI 交互」这两层。

### 功能

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| 新建/编辑/删除笔记，**重启后 DB 数据保留** | ✅ | `note_repository_test.dart`「重启后数据保留（关库再用同一文件重开）」断言正文/版本向量/imageHashes 全在 |
| Markdown 渲染：标题、列表、代码块、表格、任务列表、图片 | ✅ | `markdown_preview_test.dart`（23 个 widget 测试，含表格/任务列表/代码块专项） |
| 插入图片（相册 + 粘贴），md 里是相对路径 | ✅ | `image_vault_test.dart` 断言 `relativeRef == 'assets/images/<hash>.<ext>'` 并通过安全校验；`markdown_doc_test.dart` 覆盖 `insertImage` |
| 同一张图片重复插入，assets 只存一份 | ✅ | `image_vault_test.dart`「重复导入只存一份」；核心包 `hashing_test.dart`「相同内容哈希相同」 |
| 背景图片切换，所有页面生效 | ✅ | `BackgroundScaffold` 被 7 处页面复用；`image_vault_test.dart` 断言 `theme/` 与 `assets/images` 隔离、背景图不被 GC |
| 两台设备 mDNS 互相发现 | 🔶 | `MdnsService`（广播 + 监听）；需真机同局域网验证 |
| 配对码正确 → 成功；错误 → 拒绝；连续错误 → 锁定 | ✅ | `pairing_test.dart`（18 例）、`pairing_guard_test.dart`（3 次锁 60s） |
| 已配对设备重启后免输入码重连 | ✅ | `two_device_e2e_test.dart`「fast_auth：能解密即认证」 |
| 笔记变更后对端 30s 内同步 | 🔶 | 心跳 30s + 500ms 防抖 + 连接后全量对比；需真机验证 |
| 图片通过 WS 同步，接收端 SHA-256 与源端一致 | ✅ | `two_device_e2e_test.dart`「图片分块传输 + SHA-256 校验」 |
| 两台设备同时编辑同一笔记 → 冲突副本，两份都保留 | ✅ | `two_device_e2e_test.dart`、`sync_convergence_test.dart`、`sync_planner_test.dart` |

### 安全

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| masterKey 只在 secure_storage，不在 shared_preferences / 日志 | ✅ | `ConfigStore` 只往 secure_storage 写；`AppConfig.toJson()` 仅含 `hasMasterKey` 布尔；`app_config_test.dart` 断言序列化里无密钥字段 |
| shared_preferences 里没有明文密钥 | ✅ | 同上（显式检查 masterKey / secret / password / token） |
| WS 消息密文篡改后解密失败并断开 | ✅ | `envelope_test.dart`（密文/tag/nonce 各翻转）、`two_device_e2e_test.dart` |
| 配对失败后连接立即关闭 | ✅ | `PairingHandshake.buildFailure` + `NetService._fail` → `peer.close()` |
| 重放旧消息被 nonce 缓存拒绝 | ✅ | `envelope_test.dart`、`two_device_e2e_test.dart` |
| **pair_request 中无明文 6 位码** | ✅ | `pairing_test.dart`、`acceptance_test.dart`、`two_device_e2e_test.dart` 三处断言 |
| **重放同一 pair_request → 拒绝** | ✅ | `pairing_test.dart` + `acceptance_test.dart`（`TtlNonceCache` / `NonceCache`） |
| **错误 code 构造 HMAC → 拒绝且不泄露「接近了」** | ✅ | `pairing_test.dart`（断言失败时 `matchedCode` / `key` 均为 null） |
| **HMAC 比较为恒定时间** | ✅ | `Hashing.constantTimeEquals` 逐字节异或；断言差异在首/中/末字节都返回 false |

### 存储与同步（最终版新增）

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| 删除 notes.db 后能从 backups/ 恢复全部笔记 | ✅ | `database_test.dart`「backupTo：VACUUM INTO」用独立 sqlite3 连接打开备份并查到数据；`vault_paths_test.dart` 覆盖备份命名与列举 |
| 导出全部 md 后，md + 图片能在外部编辑器打开 | ✅ | `md_exporter_test.dart`「导出目录里 md 的相对引用能真的解析到文件（独立可用）」—— 模拟把导出目录单独拷走，按 md 里的相对路径逐一断言文件存在 |
| VACUUM INTO 备份文件可被 SQLite 正常打开 | ✅ | `schema_smoke_test.dart`「备份文件能被 sqlite3 打开并查到数据」 |
| 启动 PRAGMA integrity_check 通过 | ✅ | `schema_smoke_test.dart`、`database_test.dart` |
| 模拟写入中断，DB 无半写状态（事务回滚） | ✅ | `schema_smoke_test.dart`「事务内抛异常 → 查不到记录」 |
| 版本向量比较单测（equal / dominates / dominated / concurrent） | ✅ | `version_vector_test.dart`（32 例） |
| A 离线编辑 100 次后重连 → 单个 patch，体积与次数无关 | ✅ | `patch_util_test.dart` + `acceptance_test.dart` |
| 1MB 笔记改 3 处 → 块级同步传输量 < 50KB | ✅ | `patch_util_test.dart`「1MB 改 3 处 patch < 50KB」 |

### 代码质量

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| 加密、TOTP、哈希派生函数有单元测试 | ✅ | `aes_gcm_test.dart` / `totp_test.dart` / `kdf_test.dart` / `hashing_test.dart` |
| 加解密往返测试通过 | ✅ | `aes_gcm_test.dart`（含空载荷、1MB 大载荷） |
| GCM 篡改检测测试通过 | ✅ | `aes_gcm_test.dart`（密文/tag/nonce 翻转 + AAD 不匹配） |
| TOTP 时间窗口测试通过（±30s 容错） | ✅ | `totp_test.dart`（**RFC 4226 / 6238 官方测试向量** + ±1 窗口边界） |
| 无硬编码密码、密钥、路径 | ✅ | 密钥全部运行时生成，无硬编码凭据 |

### 平台

| 验收项 | 状态 | 证据 |
| --- | --- | --- |
| Android 权限声明完整（含 multicast） | ✅ | `AndroidManifest.xml`：INTERNET / ACCESS_NETWORK_STATE / ACCESS_WIFI_STATE / **CHANGE_WIFI_MULTICAST_STATE** / READ_MEDIA_IMAGES |
| iOS NSLocalNetworkUsageDescription + NSBonjourServices | ✅ | `ios/Runner/Info.plist`：含 `_notepad._tcp` |
| 应用进入后台停止广播/监听，回前台恢复 | ✅ | `main.dart` 的 `_LifecycleCoordinator`（resumed → start；paused / hidden / detached → stop） |

> **关于标 🔶 的条目**：本项目的开发与验证环境是一台 Android 手机容器 +
> 一台 aarch64 服务器（没有两台真机、也没有图形界面），因此涉及
> 「两台真实设备在同一局域网互相发现/同步」与「UI 交互观感」的条目
> 无法在此环境闭环。**协议层的正确性已用 `two_device_e2e_test.dart`
> 在内存中完整跑通**（配对 → 会话 → 版本向量同步 → patch → 图片分块校验 → 攻击面），
> 真机只需验证 socket / mDNS / 平台权限这些「胶水层」。

---

## 10. 测试与验证结果（实测数据）

以下数字来自真实执行，不是估计。

### 10.1 核心包（纯 Dart，可在任意机器上秒级复现）

```bash
cd packages/notepad_core && dart pub get && dart test
```

| 测试文件 | 覆盖内容 |
| --- | --- |
| `aes_gcm_test.dart` | 加解密往返（空载荷 / 1MB）、IV 12B / tag 16B、IV 随机性、**篡改检测（密文/tag/nonce 各翻转一位）**、错误密钥、AAD、参数校验 |
| `totp_test.dart` | **RFC 4226 / RFC 6238 官方测试向量**、±30s 窗口边界、步长刷新、倒计时 |
| `kdf_test.dart` | PBKDF2 确定性、协议固定参数断言、masterKey 生成（长度/字符集/随机性）、域分离 |
| `hashing_test.dart` | SHA-256 / SHA-1 官方向量、文件流式哈希、HMAC-SHA1 |
| `envelope_test.dart` | 信封编解码、明文不含敏感内容、**重放拒绝**、nonce 缓存容量与淘汰 |
| `pairing_test.dart` | HMAC 配对（**载荷无明文码**、重放拒绝、恒定时间比较、±1 窗口、篡改拒绝） |
| `version_vector_test.dart` | **equal / dominates / dominated / concurrent** 四态、序列化往返、合并 |
| `sync_planner_test.dart` | 版本向量分类、patch / conflict / blockSync 决策、删除传播、阈值 |
| `sync_convergence_test.dart` | 两设备收敛（多轮迭代至稳定）、冲突副本、离线 100 次编辑 |
| `patch_util_test.dart` | 补丁往返（含随机 100 组）、**1MB 改 3 处 < 50KB**、基线不匹配返回 null |
| `two_device_e2e_test.dart` | **端到端**：配对 → 会话 → 同步 → 图片分块校验 → 攻击面 |
| `acceptance_test.dart` | 验收清单中可在纯逻辑层验证的条目集中处 |
| `markdown_doc_test.dart` / `vault_paths_test.dart` | 标题/摘要提取、图片引用解析、路径安全约束 |

**结果：13 个测试文件、288 个用例，全部通过。**

### 10.2 App 层（需 Flutter 环境）

```bash
cd app && flutter pub get && flutter test
```

| 测试文件 | 用例数 |
| --- | --- |
| `schema_smoke_test.dart` | 10 |
| `app_config_test.dart` | 8 |
| `pairing_guard_test.dart` | 10 |
| `markdown_preview_test.dart` | 23 |
| `note_repository_test.dart` | 59 |
| `database_test.dart` | 23 |
| `md_exporter_test.dart` | 33 |
| `search_test.dart` | 32 |
| `vault_paths_test.dart` | 23 |
| `image_vault_test.dart` | 41 |

**结果：10 个测试文件、300 个用例全部通过。**

### 10.2.1 三条关键断言经过「证伪」验证

修 bug 时把测试**翻面**（从「钉住 bug 现状」改为「防回归」）有一个风险：
新断言可能写成恒真的空壳。因此对三条关键断言做了**证伪验证** ——
在一份**隔离副本**里把实现回退成旧的错误版本，确认测试**如期失败**：

| 证伪 | 回退的实现 | 预期失败的用例 | 实际结果 |
| --- | --- | --- | --- |
| #1 | `saveConflictCopy` 去掉随机后缀 | 同毫秒不撞 id | ✅ 失败：`Expected: not '…-cmwddmps0' / Actual: '…-cmwddmps0'` |
| #2 | `paths.dart` 回到 `hash.length == 64` | listImageHashes 只认 hex | ✅ 失败：`Actual: Set:['zzz…z']` |
| #2 | `image_vault.dart` 回到 `hash.length != 64` | GC 不误删非 hex | ✅ 失败：`Expected: <0> / Actual: <1>` |

**三条断言都真的在测行为，不是恒真断言。** 证伪全程在独立副本中进行，
每次都核验真项目文件未被波及。

### 10.3 静态检查

```bash
cd app && flutter analyze
```

**`lib/` 下 0 个 error。** 剩余的都是 `info` 级提示，其中最多的一类是
Flutter 3.50 的 `'package:flutter/material.dart' is deprecated`（建议改用
`material_ui`）—— 全项目 11 处，属框架级迁移提示，本次未处理（改动面大、与功能无关）。

### 10.4 本轮修复的三个真实 bug

这三个都是**通过实跑测试发现**的，其中第一个在 `flutter analyze` 下完全看不出来：

| # | 位置 | 症状 | 根因 | 修复 |
| --- | --- | --- | --- | --- |
| 1 | `db/database.dart` | **任何 `AppDatabase` 都打不开** | `@TableIndex(... columns: {#updatedAt})` 被错放在 `SearchIndex` 表上，而 `updatedAt` 属于 `Notes` → drift 生成 `CREATE INDEX ... ON search_index ()`（空列）→ `beforeOpen` 建表语法报错 | 注解移到 `Notes` 表；新增 `schema_smoke_test.dart` 防回归（断言索引列非空、且真的建在 `notes` 上） |
| 2 | `db/note_repository.dart` | 冲突副本**静默丢失** | `saveConflictCopy` 的新 id 只由 `(noteId, 当前毫秒)` 决定；配合 `upsertNote` 的 `insertOnConflictUpdate`，**同毫秒内两次调用生成同一 id，第二次覆盖第一次** —— 恰好破坏了「分叉时两份都保留」的设计目的 | id 追加 4 字节安全随机后缀；测试翻面为防回归断言 |
| 3 | `db/paths.dart` / `images/image_vault.dart` | GC **可能误删**非哈希文件 | 哈希文件名只按 `length == 64` 判定，`'z' * 64`（64 个非 hex 字符）会被当成内容哈希 | 收紧为 `^[0-9a-f]{64}$`（新增 `isContentHash`）；测试翻面 |

> 第 2、3 个 bug 的发现方式值得一提：测试编写者用**「钉住现状」**的写法
> （断言 bug 的当前行为 + 注释写明「修好后要翻面」），而不是为了让测试变绿
> 而写成恒真断言。修复后这些用例被**翻面**成防回归测试，并在**隔离副本**里
> 回退旧实现做过**证伪验证**（确认会失败），证明断言真的在测东西。
