#!/usr/bin/env python3
"""
修补 cargokit 的 Gradle 9 不兼容：Project.exec / DefaultTask.project.exec 已被移除。

背景：irondash_engine_context 0.5.5 / super_native_extensions 0.9.1 的
cargokit/gradle/plugin.gradle 在 CargoKitBuildTask（DefaultTask 子类）的
@TaskAction 方法里调用 `project.exec { }`。Gradle 9 移除了该 API，报：
  Could not find method exec() for arguments [...] on project ':xxx'
  / 在 task 里则报 Could not get unknown property 'providers'

两个包都已是 pub.dev latest，上游 cargokit 最后更新 2025-06，没有适配。

修法（两步，缺一不可）：
 1. 给脚本加 import 并在类里声明注入的 ExecOperations：
      abstract class CargoKitBuildTask extends DefaultTask {
          @Inject abstract ExecOperations getExecOperations()
      }
    Gradle 会把 ExecOperations 注入进抽象 getter。
 2. 把 `project.exec { BODY }` 换成
      execOperations.exec { BODY }.assertNormalExitValue()

⚠️ 语义要点：project.exec 在非零退出时**默认抛异常**，而 ExecOperations.exec
   不会 —— 必须显式 assertNormalExitValue()，否则构建失败会被静默吞掉。
"""
import re
import sys
from pathlib import Path

EXEC_RE = re.compile(r'(?:project\.)?exec\s*\{')
INJECT_DECL = '    @Inject abstract org.gradle.process.ExecOperations getExecOperations()\n'
CLASS_RE = re.compile(r'(abstract\s+class\s+CargoKitBuildTask\s+extends\s+DefaultTask\s*\{[^\n]*\n)')


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


def patch_file(path: Path) -> int:
    src = path.read_text()

    # ── 步骤 1：注入 ExecOperations ──────────────────────────────────
    if 'getExecOperations' not in src:
        m = CLASS_RE.search(src)
        if not m:
            print(f'  ⚠️ 找不到 CargoKitBuildTask 类声明，跳过注入：{path}')
            return 0
        src = src[:m.end()] + INJECT_DECL + src[m.end():]
    else:
        print(f'  （已注入过 ExecOperations）')

    # ── 步骤 2：替换 exec 调用 ───────────────────────────────────────
    out = []
    i = 0
    count = 0
    while True:
        m = EXEC_RE.search(src[i:])
        if not m:
            out.append(src[i:])
            break
        start = i + m.start()
        brace = i + m.end() - 1
        end = find_matching_brace(src, brace)
        body = src[brace:end + 1]
        out.append(src[i:start])
        out.append('execOperations.exec ' + body + '.assertNormalExitValue()')
        count += 1
        i = end + 1
    new = ''.join(out)

    if count or 'getExecOperations' in new:
        path.with_suffix(path.suffix + '.orig-gradle9').write_text(path.read_text())
        path.write_text(new)
    return count


def main() -> int:
    roots = sys.argv[1:] or [str(Path.home() / '.pub-cache' / 'hosted')]
    total = files = 0
    for root in roots:
        for f in Path(root).rglob('cargokit/gradle/plugin.gradle'):
            n = patch_file(f)
            if n:
                files += 1
                total += n
                print(f'  修补 {f}: {n} 处 + 注入 ExecOperations')
    print(f'共修补 {files} 个文件、{total} 处调用')
    if files == 0:
        print('⚠️ 没找到需要修补的 cargokit plugin.gradle')
    return 0


if __name__ == '__main__':
    sys.exit(main())
