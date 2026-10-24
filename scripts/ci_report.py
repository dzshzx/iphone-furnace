"""Summarize one macOS CI run from Xcode's result bundle and build artifacts."""

# ADR 0048 exemption: ios.yml runs this with the runner's system python3 under
# `if: always()`, so the report must still render when setup-uv or `uv sync`
# failed. Keep it stdlib-only and do not route it through uv.

import argparse
import json
from pathlib import Path
import re


PHASES = {
    "private-ane": "准备：私有 ANE 原生调用与模型构造",
    "models": "准备：模型、图标及工程",
    "compute-plan": "准备：Core ML 计算计划",
    "device-build": "构建：arm64 未签名 IPA",
    "simulator-tests": "测试：iOS 模拟器",
}


def clean(value):
    """Keep the summary short and avoid embedding runner paths or multiline data."""
    value = re.sub(r"(?:/Users|/home)/[^\s:]+", "[path]", str(value))
    return re.sub(r"\s+", " ", value).replace("|", "\\|")[:240]


def load_json(path):
    try:
        return json.loads(path.read_text())
    except (FileNotFoundError, ValueError):
        return None


def timings(path):
    result = {}
    if path.exists():
        for line in path.read_text().splitlines():
            name, seconds = line.split("\t")
            result[name] = int(seconds)
    return result


def preparation_seconds(root):
    try:
        start = int((root / "build/preparation-start.txt").read_text())
        end = int((root / "build/preparation-end.txt").read_text())
        return max(0, end - start)
    except (FileNotFoundError, ValueError):
        return None


def test_cases(tree):
    if not isinstance(tree, dict):
        return []
    cases = []

    def visit(node):
        if node.get("nodeType") == "Test Case":
            cases.append(node)
        for child in node.get("children", []):
            visit(child)

    for node in tree.get("testNodes", []):
        visit(node)
    return cases


def reason_lines(path):
    if not path.exists():
        return []
    return [
        clean(line)
        for line in path.read_text(errors="replace").splitlines()
        if "error:" in line.lower()
        or "failed -" in line.lower()
        or line.startswith("FAILED ")
        or "Exception:" in line
    ][:5]


def skip_reason(path, test_name):
    if test_name and path.exists():
        for line in path.read_text(errors="replace").splitlines():
            if test_name in line and "skipped -" in line.lower():
                return clean(
                    re.split(r"skipped -", line, maxsplit=1, flags=re.IGNORECASE)[1]
                )
    return "xcresult 与测试日志未提供原因；见 tests.xcresult"


PHASE_LOGS = {
    "private-ane": ("private-ane-step.log",),
    "models": ("models.log",),
    "compute-plan": ("compute-plan-build.log", "compute-plan.log"),
    "device-build": ("device-build.log",),
    "simulator-tests": ("simulator-test.log",),
}


def marketing_version(root):
    project = root / "project.yml"
    if not project.exists():
        return "unknown"
    match = re.search(
        r'^\s*MARKETING_VERSION:\s*["\']?([^"\'\s#]+)',
        project.read_text(),
        re.MULTILINE,
    )
    return match.group(1) if match else "unknown"


def header_lines(root, commit, build, versions):
    app_version = marketing_version(root)
    return [
        "# Furnace macOS 验证报告",
        "",
        f"- 提交：`{clean(commit)}`；build：`{clean(app_version)} ({clean(build)})`",
        f"- 工具：{clean(versions)}",
        "- 范围：私有 ANE 原生构造及调用替身、三档 Core ML 模型与计算计划、iOS 设备 IPA、模拟器 XCTest。",
        "- 真机安装/持续负载：pending（CI 无真机）。",
        "- Core ML 实际 ANE 执行：pending（需真机轨迹）。",
        "- 私有 ANE 编译/加载/执行：pending（需真机阶段记录及报告）。",
        "",
    ]


def seconds_or(seconds, missing):
    return f"{seconds} s" if seconds is not None else missing


def phase_lines(root, outcomes):
    """Phase table plus the preparation/build/test duration line."""
    durations = timings(root / "build/ci-timings.tsv")
    lines = ["| 阶段 | CI 结果 | 耗时 |", "|---|---|---:|"]
    for name, label in PHASES.items():
        duration = seconds_or(durations.get(name), "未开始")
        lines.append(f"| {label} | {outcomes[name]} | {duration} |")
    prepare_duration = seconds_or(preparation_seconds(root), "pending")
    build_duration = seconds_or(durations.get("device-build"), "pending")
    test_duration = seconds_or(durations.get("simulator-tests"), "pending")
    return lines + [
        "",
        f"准备/构建/测试耗时：{prepare_duration} / {build_duration} / {test_duration}",
        "",
    ]


def destination_lines(summary):
    destinations = [
        item.get("device", {}) for item in summary.get("devicesAndConfigurations", [])
    ]
    if not destinations:
        return []
    device = destinations[0]
    return [
        f"模拟器：{clean(device.get('deviceName', '?'))} / iOS {clean(device.get('osVersion', '?'))}。"
    ]


def failure_lines(summary):
    lines = [
        f"- 失败 {clean(failure.get('testIdentifierString', failure.get('testName', '?')))}：{clean(failure.get('failureText', 'xcresult 未提供原因'))}"
        for failure in summary.get("testFailures", [])
    ]
    if summary.get("failedTests", 0) and not summary.get("testFailures"):
        lines.append(
            "- 失败原因：xcresult 摘要未提供；见 tests.xcresult 和 simulator-test.log。"
        )
    return lines


def skipped_case_reason(root, case):
    details = [
        child.get("name", "")
        for child in case.get("children", [])
        if child.get("nodeType") in ("Failure Message", "Source Code Reference")
    ]
    if details:
        return clean(details[0])
    return skip_reason(root / "build/simulator-test.log", case.get("name", ""))


def skipped_lines(root, summary, cases):
    skipped = [case for case in cases if case.get("result") == "Skipped"]
    lines = [
        f"- 跳过 {clean(case.get('nodeIdentifier', case.get('name', '?')))}：{skipped_case_reason(root, case)}"
        for case in skipped
    ]
    if summary.get("skippedTests", 0) and not skipped:
        lines.append(
            "- 跳过原因：xcresult 测试树未提供条目；见 tests.xcresult 和 simulator-test.log。"
        )
    return lines


def simulator_lines(root):
    summary = load_json(root / "build/test-summary.json")
    if not summary:
        return [
            "模拟器 XCTest：无可解析的 xcresult 摘要；见 simulator-test.log 与 tests.xcresult。"
        ]
    cases = test_cases(load_json(root / "build/test-cases.json"))
    counts = "模拟器 XCTest：通过 {passedTests}、失败 {failedTests}、跳过 {skippedTests}；结果 {result}。".format(
        passedTests=summary.get("passedTests", "?"),
        failedTests=summary.get("failedTests", "?"),
        skippedTests=summary.get("skippedTests", "?"),
        result=summary.get("result", "?"),
    )
    return (
        destination_lines(summary)
        + [counts]
        + failure_lines(summary)
        + skipped_lines(root, summary, cases)
    )


def phase_outcome_lines(root, outcomes):
    """Explain each failed or skipped phase, citing its own log lines when present."""
    lines = []
    for name, outcome in outcomes.items():
        if outcome == "failure":
            reasons = [
                reason
                for filename in PHASE_LOGS[name]
                for reason in reason_lines(root / "build" / filename)
            ]
            lines.append(
                f"{PHASES[name]}失败原因："
                + (
                    "；".join(reasons[:5])
                    if reasons
                    else "见对应 Actions 步骤及诊断日志"
                )
            )
        elif outcome == "skipped":
            lines.append(
                f"{PHASES[name]}跳过原因：前置步骤未通过或未启动；见 Actions 步骤状态。"
            )
    return lines


def render(root, outcomes, commit, build, versions):
    lines = header_lines(root, commit, build, versions)
    lines += phase_lines(root, outcomes)
    lines += simulator_lines(root)
    if outcomes["device-build"] == "success":
        lines.append(
            "未签名 IPA：`scripts/verify_ipa.py` 已检查 arm64、iOS 平台、三档模型、Metal 内核及无签名。"
        )
    lines += phase_outcome_lines(root, outcomes)
    lines += [
        "",
        "证据：同次运行的 `build-diagnostics` 包含 build-info、原生检查/计算计划/构建/测试日志、xcresult 原始结果与本报告；IPA 只在升版本号的 master 运行中随 GitHub Release `v<版本号>` 发布。",
        "",
    ]
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("."))
    parser.add_argument("--commit", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--versions", required=True)
    for name in PHASES:
        parser.add_argument(
            f"--{name}",
            choices=("success", "failure", "skipped", "cancelled"),
            required=True,
        )
    args = parser.parse_args()
    outcomes = {name: getattr(args, name.replace("-", "_")) for name in PHASES}
    print(render(args.root, outcomes, args.commit, args.build, args.versions), end="")


if __name__ == "__main__":
    main()
