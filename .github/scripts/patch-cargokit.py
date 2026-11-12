#!/usr/bin/env python3
"""
修补 cargokit 的 Gradle 9 不兼容：Project.exec 已被移除，改用 providers.exec。

背景：irondash_engine_context 0.5.5 / super_native_extensions 0.9.1 的
cargokit/gradle/plugin.gradle 用了 project.exec {}，在 Gradle 9 下报：
  Could not find method exec() for arguments [...] on project ':xxx'
两包都已是 latest（上游 cargokit 最后更新 2025-06），无法靠升级解决。

替换：project.exec { BODY }  →  providers.exec { BODY }.result.get().assertNormalExitValue()

⚠️ 语义要点：project.exec 在非零退出时**默认抛异常**，
   而 providers.exec 不抛。必须显式调用 assertNormalExitValue()，
   否则构建失败会被静默吞掉（可能产出错误的产物）。
"""
import re
import sys
from pathlib import Path

REPLACEMENT_CALL = ".result.get().assertNormalExitValue()"


def find_matching_brace(s: str, open_idx: int) -> int:
    """open_idx 指向 '{'，返回与之配对的 '}' 的下标。"""
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
    raise ValueError("unbalanced braces")


def patch_file(path: Path) -> int:
    src = path.read_text()
    out = []
    i = 0
    count = 0
    while True:
        m = re.search(r'project\.exec\s*\{', src[i:])
        if not m:
            out.append(src[i:])
            break
        start = i + m.start()
        brace = i + m.end() - 1
        end = find_matching_brace(src, brace)
        body = src[brace:end + 1]
        out.append(src[i:start])
        out.append('providers.exec ' + body + REPLACEMENT_CALL)
        count += 1
        i = end + 1
    if count:
        path.with_suffix(path.suffix + '.orig-gradle9').write_text(src)
        path.write_text(''.join(out))
    return count


def main() -> int:
    roots = sys.argv[1:] or [str(Path.home() / '.pub-cache' / 'hosted')]
    total = 0
    files = 0
    for root in roots:
        for f in Path(root).rglob('cargokit/gradle/plugin.gradle'):
            n = patch_file(f)
            if n:
                files += 1
                total += n
                print(f'  修补 {f}: {n} 处')
    print(f'共修补 {files} 个文件、{total} 处调用')
    if files == 0:
        print('⚠️ 没找到含 project.exec 的 cargokit plugin.gradle')
    return 0


if __name__ == '__main__':
    sys.exit(main())
