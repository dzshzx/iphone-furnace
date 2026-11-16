import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
# macOS runner 的 /bin/bash 3.2 把紧跟变量名的多字节字符读成变量名的一部分，
# 展开为空并留下半个字符；变量后紧跟中文时须写成 ${VAR}。
UNBRACED = re.compile(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]")


def test_shell_variables_before_non_ascii_text_are_braced():
    files = [*ROOT.glob(".github/workflows/*.yml"), *ROOT.glob("scripts/*.sh")]
    assert files
    offenders = [
        f"{path.relative_to(ROOT)}:{number}"
        for path in files
        for number, line in enumerate(path.read_text().splitlines(), 1)
        if UNBRACED.search(line)
    ]
    assert offenders == []
