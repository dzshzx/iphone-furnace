package main

// ci-report: summarize one macOS CI run from Xcode's result bundle and build
// artifacts. release.yml runs it under `if: always()`, so it must render with
// whatever files the failed steps left behind.

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

type phase struct{ name, label string }

var phases = []phase{
	{"private-ane", "准备：私有 ANE 原生调用与模型构造"},
	{"models", "准备：模型、图标及工程"},
	{"compute-plan", "准备：Core ML 计算计划"},
	{"device-build", "构建：arm64 未签名 IPA"},
	{"simulator-tests", "测试：iOS 模拟器"},
}

var phaseLogs = map[string][]string{
	"private-ane":     {"private-ane-step.log"},
	"models":          {"models.log"},
	"compute-plan":    {"compute-plan-build.log", "compute-plan.log"},
	"device-build":    {"device-build.log"},
	"simulator-tests": {"simulator-test.log"},
}

// whitespace matches what Python's \s matches in a str pattern.
const whitespace = `\s\v\x1c-\x1f\x{85}\p{Z}`

var (
	runnerPath = regexp.MustCompile(`(?:/Users|/home)/[^` + whitespace + `:]+`)
	spaceRun   = regexp.MustCompile(`[` + whitespace + `]+`)
	skippedSep = regexp.MustCompile(`(?i)skipped -`)
)

// clean keeps the summary short and avoids embedding runner paths or multiline data.
func clean(value string) string {
	value = runnerPath.ReplaceAllString(value, "[path]")
	value = strings.ReplaceAll(spaceRun.ReplaceAllString(value, " "), "|", `\|`)
	runes := []rune(value)
	if len(runes) > 240 {
		runes = runes[:240]
	}
	return string(runes)
}

// loadJSON returns the decoded document, or nil when the file is missing or not valid JSON.
func loadJSON(path string) any {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var value any
	if decoder.Decode(&value) != nil || decoder.More() {
		return nil
	}
	return value
}

func timings(path string) (map[string]int, error) {
	result := map[string]int{}
	data, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return result, nil
	}
	if err != nil {
		return nil, err
	}
	for _, line := range splitLines(string(data)) {
		fields := strings.Split(line, "\t")
		if len(fields) != 2 {
			return nil, fmt.Errorf("%s: 行格式应为 <阶段>\\t<秒数>：%q", path, line)
		}
		seconds, err := strconv.Atoi(strings.TrimSpace(fields[1]))
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		result[fields[0]] = seconds
	}
	return result, nil
}

func readInt(path string) (int, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(data)))
	return n, err == nil
}

// preparationSeconds returns the preparation duration, or false when unknown.
func preparationSeconds(root string) (int, bool) {
	start, ok := readInt(filepath.Join(root, "build/preparation-start.txt"))
	if !ok {
		return 0, false
	}
	end, ok := readInt(filepath.Join(root, "build/preparation-end.txt"))
	if !ok {
		return 0, false
	}
	return max(0, end-start), true
}

func testCases(tree any) []map[string]any {
	object, ok := tree.(map[string]any)
	if !ok {
		return nil
	}
	var cases []map[string]any
	var visit func(map[string]any)
	visit = func(node map[string]any) {
		if node["nodeType"] == "Test Case" {
			cases = append(cases, node)
		}
		for _, child := range objects(node["children"]) {
			visit(child)
		}
	}
	for _, node := range objects(object["testNodes"]) {
		visit(node)
	}
	return cases
}

func isReasonLine(line string) bool {
	lower := strings.ToLower(line)
	return strings.Contains(lower, "error:") || strings.Contains(lower, "failed -") ||
		strings.HasPrefix(line, "FAILED ") || strings.Contains(line, "Exception:")
}

func reasonLines(path string) []string {
	text, err := readReplacing(path)
	if err != nil {
		return nil
	}
	var reasons []string
	for _, line := range splitLines(text) {
		if isReasonLine(line) && len(reasons) < 5 {
			reasons = append(reasons, clean(line))
		}
	}
	return reasons
}

func skipReason(path, testName string) string {
	if testName != "" {
		if text, err := readReplacing(path); err == nil {
			for _, line := range splitLines(text) {
				if strings.Contains(line, testName) && strings.Contains(strings.ToLower(line), "skipped -") {
					return clean(skippedSep.Split(line, 2)[1])
				}
			}
		}
	}
	return "xcresult 与测试日志未提供原因；见 tests.xcresult"
}

type reportInput struct {
	root                            string
	outcomes                        map[string]string
	commit, appVersion, build, tool string
}

func headerLines(in reportInput) []string {
	return []string{
		"# Furnace macOS 验证报告",
		"",
		fmt.Sprintf("- 提交：`%s`；build：`%s (%s)`", clean(in.commit), clean(in.appVersion), clean(in.build)),
		"- 工具：" + clean(in.tool),
		"- 范围：私有 ANE 原生构造及调用替身、三档 Core ML 模型与计算计划、iOS 设备 IPA、模拟器 XCTest。",
		"- 真机安装/持续负载：pending（CI 无真机）。",
		"- Core ML 实际 ANE 执行：pending（需真机轨迹）。",
		"- 私有 ANE 编译/加载/执行：pending（需真机阶段记录及报告）。",
		"",
	}
}

func secondsOr(seconds int, known bool, missing string) string {
	if !known {
		return missing
	}
	return fmt.Sprintf("%d s", seconds)
}

// phaseLines renders the phase table plus the preparation/build/test duration line.
func phaseLines(in reportInput) ([]string, error) {
	durations, err := timings(filepath.Join(in.root, "build/ci-timings.tsv"))
	if err != nil {
		return nil, err
	}
	duration := func(name, missing string) string {
		seconds, ok := durations[name]
		return secondsOr(seconds, ok, missing)
	}
	lines := []string{"| 阶段 | CI 结果 | 耗时 |", "|---|---|---:|"}
	for _, p := range phases {
		lines = append(lines, fmt.Sprintf("| %s | %s | %s |", p.label, in.outcomes[p.name], duration(p.name, "未开始")))
	}
	prepare, ok := preparationSeconds(in.root)
	return append(lines,
		"",
		fmt.Sprintf("准备/构建/测试耗时：%s / %s / %s", secondsOr(prepare, ok, "pending"),
			duration("device-build", "pending"), duration("simulator-tests", "pending")),
		"",
	), nil
}

func destinationLines(summary map[string]any) []string {
	destinations := objects(get(summary, "devicesAndConfigurations", []any{}))
	if len(destinations) == 0 {
		return nil
	}
	device, _ := get(destinations[0], "device", map[string]any{}).(map[string]any)
	return []string{fmt.Sprintf("模拟器：%s / iOS %s。",
		clean(pyStr(get(device, "deviceName", "?"))), clean(pyStr(get(device, "osVersion", "?"))))}
}

func failureLines(summary map[string]any) []string {
	var lines []string
	failures := objects(get(summary, "testFailures", []any{}))
	for _, failure := range failures {
		name := get(failure, "testIdentifierString", get(failure, "testName", "?"))
		lines = append(lines, fmt.Sprintf("- 失败 %s：%s",
			clean(pyStr(name)), clean(pyStr(get(failure, "failureText", "xcresult 未提供原因")))))
	}
	if truthy(get(summary, "failedTests", json.Number("0"))) && !truthy(summary["testFailures"]) {
		lines = append(lines, "- 失败原因：xcresult 摘要未提供；见 tests.xcresult 和 simulator-test.log。")
	}
	return lines
}

func skippedCaseReason(root string, testCase map[string]any) string {
	for _, child := range objects(testCase["children"]) {
		if kind := child["nodeType"]; kind == "Failure Message" || kind == "Source Code Reference" {
			return clean(pyStr(get(child, "name", "")))
		}
	}
	return skipReason(filepath.Join(root, "build/simulator-test.log"), pyStr(get(testCase, "name", "")))
}

func skippedLines(root string, summary map[string]any, cases []map[string]any) []string {
	var lines []string
	for _, testCase := range cases {
		if testCase["result"] != "Skipped" {
			continue
		}
		name := get(testCase, "nodeIdentifier", get(testCase, "name", "?"))
		lines = append(lines, fmt.Sprintf("- 跳过 %s：%s", clean(pyStr(name)), skippedCaseReason(root, testCase)))
	}
	if truthy(get(summary, "skippedTests", json.Number("0"))) && len(lines) == 0 {
		lines = append(lines, "- 跳过原因：xcresult 测试树未提供条目；见 tests.xcresult 和 simulator-test.log。")
	}
	return lines
}

func simulatorLines(root string) []string {
	summary, _ := loadJSON(filepath.Join(root, "build/test-summary.json")).(map[string]any)
	if len(summary) == 0 {
		return []string{"模拟器 XCTest：无可解析的 xcresult 摘要；见 simulator-test.log 与 tests.xcresult。"}
	}
	cases := testCases(loadJSON(filepath.Join(root, "build/test-cases.json")))
	counts := fmt.Sprintf("模拟器 XCTest：通过 %s、失败 %s、跳过 %s；结果 %s。",
		pyStr(get(summary, "passedTests", "?")), pyStr(get(summary, "failedTests", "?")),
		pyStr(get(summary, "skippedTests", "?")), pyStr(get(summary, "result", "?")))
	lines := append(destinationLines(summary), counts)
	lines = append(lines, failureLines(summary)...)
	return append(lines, skippedLines(root, summary, cases)...)
}

// phaseOutcomeLines explains each failed or skipped phase, citing its own log lines when present.
func phaseOutcomeLines(in reportInput) []string {
	var lines []string
	for _, p := range phases {
		switch in.outcomes[p.name] {
		case "failure":
			var reasons []string
			for _, name := range phaseLogs[p.name] {
				reasons = append(reasons, reasonLines(filepath.Join(in.root, "build", name))...)
			}
			reason := "见对应 Actions 步骤及诊断日志"
			if len(reasons) > 0 {
				reason = strings.Join(reasons[:min(5, len(reasons))], "；")
			}
			lines = append(lines, p.label+"失败原因："+reason)
		case "skipped":
			lines = append(lines, p.label+"跳过原因：前置步骤未通过或未启动；见 Actions 步骤状态。")
		}
	}
	return lines
}

func render(in reportInput) (string, error) {
	table, err := phaseLines(in)
	if err != nil {
		return "", err
	}
	lines := append(headerLines(in), table...)
	lines = append(lines, simulatorLines(in.root)...)
	if in.outcomes["device-build"] == "success" {
		lines = append(lines, "未签名 IPA：`furnace-tools verify-ipa` 已检查 arm64、iOS 平台、三档模型、Metal 内核及无签名。")
	}
	lines = append(lines, phaseOutcomeLines(in)...)
	lines = append(lines,
		"",
		"证据：同次运行的 `build-diagnostics` 包含 build-info、原生检查/计算计划/构建/测试日志、xcresult 原始结果与本报告；IPA 只在非 dry_run 的发版运行中随 GitHub Release `v<版本号>` 发布。",
		"",
	)
	return strings.Join(lines, "\n") + "\n", nil
}

func ciReportMain(args []string, _ io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("ci-report", stderr)
	in := reportInput{outcomes: map[string]string{}}
	flags.StringVar(&in.root, "root", ".", "仓库根目录")
	flags.StringVar(&in.commit, "commit", "", "源提交（必填）")
	flags.StringVar(&in.appVersion, "version", "", "版本号（必填）")
	flags.StringVar(&in.build, "build", "", "build 号（必填）")
	flags.StringVar(&in.tool, "versions", "", "工具版本（必填）")
	outcomes := map[string]*string{}
	for _, p := range phases {
		outcomes[p.name] = flags.String(p.name, "", "success、failure、skipped 或 cancelled（必填）")
	}
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		return err
	}
	if len(positional) > 0 {
		fmt.Fprintf(stderr, "多余的参数：%v\n", positional)
		return errUsage
	}
	set := map[string]bool{}
	flags.Visit(func(f *flag.Flag) { set[f.Name] = true })
	for _, name := range []string{"commit", "version", "build", "versions"} {
		if !set[name] {
			fmt.Fprintf(stderr, "缺少 --%s\n", name)
			return errUsage
		}
	}
	for _, p := range phases {
		if err := requireChoice(stderr, p.name, *outcomes[p.name], "success", "failure", "skipped", "cancelled"); err != nil {
			return err
		}
		in.outcomes[p.name] = *outcomes[p.name]
	}
	report, err := render(in)
	if err != nil {
		return err
	}
	_, err = io.WriteString(stdout, report)
	return err
}
