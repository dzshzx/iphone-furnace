package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReleaseSummaryPrintsPlanAndWritesNotes(t *testing.T) {
	dir := t.TempDir()
	writeFiles(t, dir, map[string]string{"Furnace-unsigned.ipa": "ipa", "validation-report.md": "# report\n\n"})
	ipa := filepath.Join(dir, "Furnace-unsigned.ipa")
	notes := filepath.Join(dir, "release-notes.md")
	commit := strings.Repeat("c", 40)
	for _, dryRun := range []bool{false, true} {
		args := []string{"release-summary", "--tag", "v0.1.1", "--build", "1001", "--commit", commit,
			"--report", filepath.Join(dir, "validation-report.md"), "--notes", notes, ipa}
		want := "## 发版计划\n\n- 版本：`v0.1.1`（build 1001）\n- 源提交：`" + commit + "`\n- 资产 sha256：\n" +
			// sha256("ipa"), in the `shasum -a 256` layout.
			"  - 78324857e8d9bfa749dc301271df54a6572de9f4c3df8a9507cfa7b7d2b25f8e  Furnace-unsigned.ipa\n"
		if dryRun {
			args = append(args, "--dry-run")
			want += "\ndry_run：不打 tag、不发布。\n"
		}
		code, stdout, stderr := runCLI("", args...)
		if code != 0 || stdout != want {
			t.Fatalf("dry_run=%t code=%d stderr=%q\nstdout=%q\nwant  =%q", dryRun, code, stderr, stdout, want)
		}
		data, err := os.ReadFile(notes)
		if err != nil || string(data) != "# report\n\n\nsource_commit: `"+commit+"`\n" {
			t.Fatalf("notes %q, %v", data, err)
		}
	}
}

func TestReleaseSummaryRequiresAssetsAndFlags(t *testing.T) {
	if code, _, stderr := runCLI("", "release-summary", "--tag", "v0.1.1"); code != 2 || !strings.Contains(stderr, "缺少 --build") {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
	code, _, stderr := runCLI("", "release-summary", "--tag", "v", "--build", "1", "--commit", "c", "--report", "r", "--notes", "n")
	if code != 2 || !strings.Contains(stderr, "用法") {
		t.Fatalf("code=%d stderr=%q", code, stderr)
	}
}
