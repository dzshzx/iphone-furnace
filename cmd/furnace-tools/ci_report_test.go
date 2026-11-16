package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func allOutcomes(outcome string) map[string]string {
	outcomes := map[string]string{}
	for _, p := range phases {
		outcomes[p.name] = outcome
	}
	return outcomes
}

func mustRender(t *testing.T, in reportInput) string {
	t.Helper()
	report, err := render(in)
	if err != nil {
		t.Fatal(err)
	}
	return report
}

func assertContains(t *testing.T, report string, wants ...string) {
	t.Helper()
	for _, want := range wants {
		if !strings.Contains(report, want) {
			t.Errorf("report lacks %q:\n%s", want, report)
		}
	}
}

func writeFiles(t *testing.T, dir string, files map[string]string) {
	t.Helper()
	for name, content := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestReportKeepsSimulatorIPAAndDeviceEvidenceSeparate(t *testing.T) {
	root := t.TempDir()
	build := filepath.Join(root, "build")
	if err := os.Mkdir(build, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFiles(t, build, map[string]string{
		"ci-timings.tsv":        "private-ane\t3\nmodels\t10\ncompute-plan\t2\ndevice-build\t20\nsimulator-tests\t30\n",
		"preparation-start.txt": "100\n",
		"preparation-end.txt":   "120\n",
		"test-summary.json": `{"passedTests": 15, "failedTests": 1, "skippedTests": 1, "result": "Failed",
			"testFailures": [{"testIdentifierString": "SessionTests/fail()", "failureText": "expected 1 but got 0"}]}`,
		"test-cases.json": `{"testNodes": [{"children": [{"nodeType": "Test Case", "name": "skip()",
			"nodeIdentifier": "SessionTests/skip()", "result": "Skipped"}]}]}`,
		"simulator-test.log": "skip() skipped - Host has no Metal device\n",
	})
	outcomes := allOutcomes("success")
	outcomes["simulator-tests"] = "failure"
	report := mustRender(t, reportInput{root, outcomes, "abc123", "0.1.1", "1001", "Xcode 27.0"})
	assertContains(t, report,
		"准备/构建/测试耗时：20 s / 20 s / 30 s",
		"通过 15、失败 1、跳过 1",
		"expected 1 but got 0",
		"\n- 跳过 SessionTests/skip()： Host has no Metal device\n",
		"未签名 IPA",
		"真机安装/持续负载：pending",
		"ANE 执行",
	)
}

func TestReportMarksMissingMacResultsPending(t *testing.T) {
	report := mustRender(t, reportInput{t.TempDir(), allOutcomes("skipped"), "abc123", "0.1.1", "1001", "Xcode unavailable"})
	assertContains(t, report, "准备/构建/测试耗时：pending / pending / pending", "无可解析的 xcresult 摘要")
	if strings.Contains(report, "已检查 arm64") {
		t.Errorf("skipped device build still claims a verified IPA:\n%s", report)
	}
}

func TestReportHeaderNamesTheReleaseVersionAndBuild(t *testing.T) {
	report := mustRender(t, reportInput{t.TempDir(), allOutcomes("skipped"), "abc123", "0.1.1", "1001", "Xcode"})
	assertContains(t, report, "提交：`abc123`；build：`0.1.1 (1001)`")
}
