import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from ci_report import render


def test_report_keeps_simulator_ipa_and_device_evidence_separate(tmp_path):
    build = tmp_path / "build"
    build.mkdir()
    (build / "ci-timings.tsv").write_text(
        "private-ane\t3\nmodels\t10\ncompute-plan\t2\ndevice-build\t20\nsimulator-tests\t30\n"
    )
    (build / "preparation-start.txt").write_text("100\n")
    (build / "preparation-end.txt").write_text("120\n")
    (build / "test-summary.json").write_text(
        json.dumps(
            {
                "passedTests": 15,
                "failedTests": 1,
                "skippedTests": 1,
                "result": "Failed",
                "testFailures": [
                    {
                        "testIdentifierString": "SessionTests/fail()",
                        "failureText": "expected 1 but got 0",
                    }
                ],
            }
        )
    )
    (build / "test-cases.json").write_text(
        json.dumps(
            {
                "testNodes": [
                    {
                        "children": [
                            {
                                "nodeType": "Test Case",
                                "name": "skip()",
                                "nodeIdentifier": "SessionTests/skip()",
                                "result": "Skipped",
                            }
                        ]
                    }
                ]
            }
        )
    )
    (build / "simulator-test.log").write_text(
        "skip() skipped - Host has no Metal device\n"
    )
    outcomes = {
        name: "success"
        for name in (
            "private-ane",
            "models",
            "compute-plan",
            "device-build",
            "simulator-tests",
        )
    }
    outcomes["simulator-tests"] = "failure"
    report = render(tmp_path, outcomes, "abc123", "42", "Xcode 27.0")
    assert "准备/构建/测试耗时：20 s / 20 s / 30 s" in report
    assert "通过 15、失败 1、跳过 1" in report
    assert "expected 1 but got 0" in report
    assert "Host has no Metal device" in report
    assert "未签名 IPA" in report
    assert "真机安装/持续负载：pending" in report
    assert "ANE 执行" in report


def test_report_marks_missing_mac_results_pending(tmp_path):
    outcomes = {
        name: "skipped"
        for name in (
            "private-ane",
            "models",
            "compute-plan",
            "device-build",
            "simulator-tests",
        )
    }
    report = render(tmp_path, outcomes, "abc123", "42", "Xcode unavailable")
    assert "准备/构建/测试耗时：pending / pending / pending" in report
    assert "无可解析的 xcresult 摘要" in report
    assert "已检查 arm64" not in report


def test_report_reads_marketing_version_in_either_quote_style(tmp_path):
    outcomes = {
        name: "skipped"
        for name in (
            "private-ane",
            "models",
            "compute-plan",
            "device-build",
            "simulator-tests",
        )
    }
    for line in (
        'MARKETING_VERSION: "1.2.3"',
        "MARKETING_VERSION: '1.2.3'",
        "MARKETING_VERSION: 1.2.3",
    ):
        (tmp_path / "project.yml").write_text(f"settings:\n  base:\n    {line}\n")
        assert "build：`1.2.3 (42)`" in render(
            tmp_path, outcomes, "abc123", "42", "Xcode"
        )
