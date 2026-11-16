package main

// release-summary: release.yml's publish step prints the release plan into the
// run summary and writes the GitHub Release notes with it. Building this
// Markdown in Go keeps non-ASCII text out of the macOS runner's shell.

import (
	"crypto/sha256"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// sha256Line matches what `shasum -a 256 <name>` prints for a file in the current directory.
func sha256Line(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return "", err
	}
	return fmt.Sprintf("%x  %s", digest.Sum(nil), filepath.Base(path)), nil
}

type releaseSummaryArgs struct {
	tag, build, commit, report, notes string
	dryRun                            bool
	assets                            []string
}

func releasePlanSummary(a releaseSummaryArgs) (string, error) {
	lines := []string{
		"## 发版计划",
		"",
		fmt.Sprintf("- 版本：`%s`（build %s）", a.tag, a.build),
		fmt.Sprintf("- 源提交：`%s`", a.commit),
		"- 资产 sha256：",
	}
	for _, asset := range a.assets {
		line, err := sha256Line(asset)
		if err != nil {
			return "", err
		}
		lines = append(lines, "  - "+line)
	}
	if a.dryRun {
		lines = append(lines, "", "dry_run：不打 tag、不发布。")
	}
	return strings.Join(lines, "\n") + "\n", nil
}

// releaseNotes is the validation report followed by the source commit.
func releaseNotes(report []byte, commit string) []byte {
	return fmt.Appendf(report, "\nsource_commit: `%s`\n", commit)
}

func releaseSummaryMain(args []string, _ io.Reader, stdout, stderr io.Writer) error {
	var a releaseSummaryArgs
	flags := newFlags("release-summary", stderr)
	flags.StringVar(&a.tag, "tag", "", "要发布的 tag，如 v0.1.1（必填）")
	flags.StringVar(&a.build, "build", "", "build 号（必填）")
	flags.StringVar(&a.commit, "commit", "", "源提交（必填）")
	flags.StringVar(&a.report, "report", "", "validation-report.md 的路径（必填）")
	flags.StringVar(&a.notes, "notes", "", "写出 Release 正文的路径（必填）")
	flags.BoolVar(&a.dryRun, "dry-run", false, "在摘要末尾注明不打 tag、不发布")
	assets, err := parseInterspersed(flags, args)
	if err != nil {
		return err
	}
	for _, name := range []string{"tag", "build", "commit", "report", "notes"} {
		if flags.Lookup(name).Value.String() == "" {
			fmt.Fprintf(stderr, "缺少 --%s\n", name)
			return errUsage
		}
	}
	if len(assets) == 0 {
		fmt.Fprintln(stderr, "用法：furnace-tools release-summary --tag T --build B --commit C --report R --notes N <资产>...")
		return errUsage
	}
	a.assets = assets
	summary, err := releasePlanSummary(a)
	if err != nil {
		return err
	}
	report, err := os.ReadFile(a.report)
	if err != nil {
		return err
	}
	if err := os.WriteFile(a.notes, releaseNotes(report, a.commit), 0o644); err != nil {
		return err
	}
	_, err = io.WriteString(stdout, summary)
	return err
}
