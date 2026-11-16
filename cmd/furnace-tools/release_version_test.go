package main

import (
	"bytes"
	"reflect"
	"sort"
	"strings"
	"testing"
)

var (
	headSHA  = strings.Repeat("c", 40)
	zeroSHA  = strings.Repeat("0", 40)
	lsRemote = strings.Join([]string{
		strings.Repeat("a", 40) + "\trefs/tags/v0.1.0",
		headSHA + "\trefs/tags/v0.1.0^{}",
		strings.Repeat("b", 40) + "\trefs/tags/v0.9.0",
		strings.Repeat("d", 40) + "\trefs/tags/v0.10.0-rc1",
		strings.Repeat("e", 40) + "\trefs/tags/v1.0",
		strings.Repeat("f", 40) + "\trefs/tags/release-2.0.0",
		strings.Repeat("1", 40) + "\trefs/tags/v0.10.0x",
		strings.Repeat("2", 40) + "\trefs/heads/v9.9.9",
	}, "\n")
)

func mustPlan(t *testing.T, tags, bump, head string) releasePlan {
	t.Helper()
	result, err := plan(tags, bump, head)
	if err != nil {
		t.Fatal(err)
	}
	return result
}

func TestBumpsTheHighestPureSemverTag(t *testing.T) {
	for bump, want := range map[string]string{"patch": "0.9.1", "minor": "0.10.0", "major": "1.0.0"} {
		t.Run(bump, func(t *testing.T) {
			if got := mustPlan(t, lsRemote, bump, zeroSHA).version; got != want {
				t.Fatalf("got %s, want %s", got, want)
			}
		})
	}
}

func TestComparesNumericallyNotAsText(t *testing.T) {
	tags := strings.Repeat("a", 40) + "\trefs/tags/v0.9.0\n" + strings.Repeat("b", 40) + "\trefs/tags/v0.10.0\n"
	if got := mustPlan(t, tags, "patch", headSHA).version; got != "0.10.1" {
		t.Fatalf("got %s", got)
	}
}

func TestFirstReleaseStartsFromZero(t *testing.T) {
	result := mustPlan(t, "", "patch", headSHA)
	if result.version != "0.0.1" || result.build != 1 {
		t.Fatalf("got %s (%d)", result.version, result.build)
	}
}

func TestReportsPureTagsOnHeadThroughPeeledAnnotatedRefs(t *testing.T) {
	if got := mustPlan(t, lsRemote, "patch", headSHA).onHead; !reflect.DeepEqual(got, []string{"v0.1.0"}) {
		t.Fatalf("got %v", got)
	}
	if got := mustPlan(t, lsRemote, "patch", zeroSHA).onHead; len(got) != 0 {
		t.Fatalf("got %v", got)
	}
}

func TestBuildNumberGrowsWithEveryVersionOrder(t *testing.T) {
	ordered := []version{{0, 1, 0}, {0, 1, 1}, {0, 1, 999}, {0, 2, 0}, {0, 999, 999}, {1, 0, 0}}
	var numbers []int
	seen := map[int]bool{}
	for _, v := range ordered {
		n, err := buildNumber(v)
		if err != nil {
			t.Fatal(err)
		}
		numbers = append(numbers, n)
		seen[n] = true
	}
	if !sort.IntsAreSorted(numbers) || len(seen) != len(numbers) {
		t.Fatalf("build numbers not strictly increasing: %v", numbers)
	}
	if n, _ := buildNumber(version{0, 1, 1}); n != 1001 {
		t.Fatalf("0.1.1 -> %d", n)
	}
	if _, err := buildNumber(version{0, 1000, 0}); err == nil {
		t.Fatal("minor 1000 accepted")
	}
}

func runCLI(stdin string, args ...string) (code int, stdout, stderr string) {
	var out, errOut bytes.Buffer
	code = run(args, strings.NewReader(stdin), &out, &errOut)
	return code, out.String(), errOut.String()
}

func TestCLIPrintsGitHubOutputs(t *testing.T) {
	code, stdout, stderr := runCLI(lsRemote, "release-version", "--bump", "patch", "--head", zeroSHA, "--require-unreleased")
	if code != 0 || stdout != "version=0.9.1\nbuild=9001\ntag=v0.9.1\n" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
}

func TestCLIRefusesAHeadThatIsAlreadyReleasedUnlessDryRun(t *testing.T) {
	code, stdout, stderr := runCLI(lsRemote, "release-version", "--bump", "patch", "--head", headSHA, "--require-unreleased")
	if code == 0 || !strings.Contains(stderr, "已发过版") || stdout != "" {
		t.Fatalf("code=%d stdout=%q stderr=%q", code, stdout, stderr)
	}
	if code, _, stderr := runCLI(lsRemote, "release-version", "--bump", "patch", "--head", headSHA); code != 0 {
		t.Fatalf("dry run refused: %s", stderr)
	}
}
