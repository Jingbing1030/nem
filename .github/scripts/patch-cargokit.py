#!/usr/bin/env python3
"""
CI 构建前的就地补丁：修掉两个上游（cargokit 家族）插件的 AGP 9 / Gradle 9 不兼容。

涉及包（都已是 pub.dev latest，上游未适配）：
  - irondash_engine_context 0.5.5
  - super_native_extensions   0.9.1

## 补丁 1：Gradle 9 移除了 Project.exec()

`cargokit/gradle/plugin.gradle` 在 CargoKitBuildTask（DefaultTask 子类）的
@TaskAction 里调用 `project.exec { }`。Gradle 9 已彻底移除该 API：
    javap org/gradle/api/Project.class | grep -c exec   → 0
报错：
    > Could not find method exec() for arguments [...] on project ':xxx'
    或（若误用裸 providers） Could not get unknown property 'providers'
      for task '...' of type CargoKitBuildTask

修法：
  1) 给 CargoKitBuildTask 注入 ExecOperations：
       @Inject abstract org.gradle.process.ExecOperations getExecOperations()
     （DefaultTask 上没有 providers；必须走 @Inject 服务注入）
  2) project.exec { BODY }  →  execOperations.exec { BODY }.assertNormalExitValue()

  ⚠️ assertNormalExitValue() 不可省：project.exec 非零退出默认抛异常，
     ExecOperations.exec 不抛，不调就会静默吞掉构建失败。

## 补丁 2：插件硬编码 compileSdkVersion 31，低于 androidx 要求

两个插件的 android/build.gradle 都写死 `compileSdkVersion 31`，
而它们传递依赖的 androidx 库要求 ≥34（AAR metadata 检查失败）：
    Execution failed for task ':irondash_engine_context:checkDebugAarMetadata'
    > Dependency 'androidx.fragment:fragment:1.7.1' requires ... version 34 or later.
      :irondash_engine_context is currently compiled against android-31.

修法：把 `compileSdkVersion 31` 抬到 Flutter 3.50 的默认值 36。
      只影响编译期 API 级别，不动 minSdk/targetSdk。

两个补丁都只改 CI runner 的 pub-cache 副本，**业务源码零改动**。
将来源码修好后，本脚本可整体删除。
"""
import re
import sys
from pathlib import Path

# ── 目标值 ────────────────────────────────────────────────────────────
# Flutter 3.50 的 FlutterExtension.compileSdkVersion 默认值
TARGET_COMPILE_SDK = 36

# ⚠️ 必须要求 `project.` 前缀：
#   替换后的代码是 `execOperations.exec { ... }`，若正则里 project. 是可选的，
#   第二次运行会匹配其中的 `exec {` → 变成 `execOperations.execOperations.exec {`
#   → 报 "Could not get unknown property 'execOperations'"（CI run #8 实测）。
EXEC_RE = re.compile(r'project\.exec\s*\{')
INJECT_DECL = '    @Inject abstract org.gradle.process.ExecOperations getExecOperations()\n'
CLASS_RE = re.compile(r'(abstract\s+class\s+CargoKitBuildTask\s+extends\s+DefaultTask\s*\{[^\n]*\n)')
COMPILE_SDK_RE = re.compile(r'compileSdkVersion\s+(\d+)')



# 已损坏形式（历史 bug 造成）：execOperations.execOperations.exec → execOperations.exec
# 因为 flutter-action 的 cache:true 会把 patch 过的 pub-cache 存进缓存，
# 于是下一次运行会在已打补丁的文件上再打一遍。这里做幂等自修复。
BROKEN_DOUBLE = 'execOperations.execOperations.exec'
BROKEN_FIXED = 'execOperations.exec'


def repair_double_patch(src: str) -> tuple[str, int]:
    """把历史上被重复 patch 的 `execOperations.execOperations.exec` 修回单层。"""
    n = src.count(BROKEN_DOUBLE)
    if n:
        src = src.replace(BROKEN_DOUBLE, BROKEN_FIXED)
    return src, n


def find_matching_brace(s: str, open_idx: int) -> int:
    depth = 0
    i = open_idx
    while i < len(s):
        c = s[i]
        if c == '{':
            depth += 1
        elif c == '}':
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise ValueError('unbalanced braces')


def patch_cargokit_gradle(path: Path) -> int:
    original = path.read_text()   # 用于最后判断"文件是否真的变了"
    src = original

    # 补丁 0：自修复历史遗留的 double-patch
    src, repaired = repair_double_patch(src)
    if repaired:
        print(f'  自修复重复补丁 {repaired} 处：{path}')

    # 补丁 1a：注入 ExecOperations（幂等）
    if 'getExecOperations' not in src:
        m = CLASS_RE.search(src)
        if not m:
            print(f'  ⚠️ 找不到 CargoKitBuildTask 类声明，跳过：{path}')
            return 0
        src = src[:m.end()] + INJECT_DECL + src[m.end():]

    # 补丁 1b：替换 exec 调用
    out, i, count = [], 0, 0
    while True:
        m = EXEC_RE.search(src[i:])
        if not m:
            out.append(src[i:])
            break
        start = i + m.start()
        brace = i + m.end() - 1
        end = find_matching_brace(src, brace)
        out.append(src[i:start])
        out.append('execOperations.exec ' + src[brace:end + 1] + '.assertNormalExitValue()')
        count += 1
        i = end + 1
    new = ''.join(out)

    # 判据必须与**原始内容**比较：自修复时 count 可能为 0，
    # 此时 new == src（都含修复），若拿 new 和 src 比就永远不写回 —— 那是 bug。
    if new != original:
        path.write_text(new)
    return count


def patch_compile_sdk(path: Path) -> bool:
    """把过低的 compileSdkVersion 抬到 TARGET_COMPILE_SDK。"""
    src = path.read_text()
    m = COMPILE_SDK_RE.search(src)
    if not m:
        return False
    cur = int(m.group(1))
    if cur >= TARGET_COMPILE_SDK:
        return False
    new = COMPILE_SDK_RE.sub(f'compileSdkVersion {TARGET_COMPILE_SDK}', src)
    path.write_text(new)
    print(f'  compileSdk {cur} → {TARGET_COMPILE_SDK}：{path}')
    return True


def main() -> int:
    roots = sys.argv[1:] or [str(Path.home() / '.pub-cache' / 'hosted')]
    exec_files = exec_calls = sdk_files = 0
    for root in roots:
        for f in sorted(Path(root).rglob('cargokit/gradle/plugin.gradle')):
            n = patch_cargokit_gradle(f)
            if n:
                exec_files += 1
                exec_calls += n
                print(f'  修补 exec：{f}（{n} 处 + 注入 ExecOperations）')
        # 两个 cargokit 插件的 android/build.gradle
        for pkg in ('irondash_engine_context', 'super_native_extensions'):
            for f in sorted(Path(root).rglob(f'{pkg}-*/android/build.gradle')):
                if patch_compile_sdk(f):
                    sdk_files += 1

    print(f'\n汇总：exec 补丁 {exec_files} 个文件 / {exec_calls} 处；'
          f'compileSdk 补丁 {sdk_files} 个文件')
    if exec_files == 0:
        print('⚠️ 没找到需要打 exec 补丁的 cargokit plugin.gradle')
    return 0


if __name__ == '__main__':
    sys.exit(main())
