package main

// release-version: release.yml pipes `git ls-remote --tags <repo>` into this
// subcommand, passes the tag names of the published GitHub Releases in a file
// and appends its key=value output to $GITHUB_OUTPUT.

import (
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
)

var pureTag = regexp.MustCompile(`^refs/tags/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\^\{\})?$`)

// componentLimit keeps CFBundleVersion growing with every release:
// major * 1_000_000 + minor * 1_000 + patch.
const componentLimit = 1000

type version [3]int

func (v version) String() string { return fmt.Sprintf("%d.%d.%d", v[0], v[1], v[2]) }

func (v version) less(other version) bool {
	for i := range v {
		if v[i] != other[i] {
			return v[i] < other[i]
		}
	}
	return false
}

type taggedVersion struct {
	sha     string
	version version
}

// pureTags returns (commit-or-tag-object sha, version) for each pure vX.Y.Z ref.
func pureTags(lsRemote string) []taggedVersion {
	var tags []taggedVersion
	for _, line := range splitLines(lsRemote) {
		parts := strings.Fields(line)
		if len(parts) != 2 {
			continue
		}
		match := pureTag.FindStringSubmatch(parts[1])
		if match == nil {
			continue
		}
		var v version
		valid := true
		for i := range v {
			n, err := strconv.Atoi(match[i+1])
			if err != nil {
				valid = false
				break
			}
			v[i] = n
		}
		if valid {
			tags = append(tags, taggedVersion{parts[0], v})
		}
	}
	return tags
}

func bumpVersion(base version, bump string) version {
	switch bump {
	case "major":
		return version{base[0] + 1, 0, 0}
	case "minor":
		return version{base[0], base[1] + 1, 0}
	default:
		return version{base[0], base[1], base[2] + 1}
	}
}

func buildNumber(v version) (int, error) {
	if v[1] >= componentLimit || v[2] >= componentLimit {
		return 0, fmt.Errorf("minor 与 patch 须小于 %d，build 号公式才单调递增", componentLimit)
	}
	return v[0]*1_000_000 + v[1]*1_000 + v[2], nil
}

type releasePlan struct {
	version  string
	build    int
	resume   bool     // head already carries the tag of an unpublished release
	released []string // pure tags on head whose GitHub Release is published, sorted
}

// plan bumps the highest pure tag, unless head already carries a pure tag
// without a published Release: that release did not finish, so it resumes
// with the tag's version.
func plan(lsRemote, bump, head string, published map[string]bool) (releasePlan, error) {
	var base, unpublished version
	resume := false
	released := []string{}
	for _, tag := range pureTags(lsRemote) {
		if base.less(tag.version) {
			base = tag.version
		}
		if tag.sha != head {
			continue
		}
		name := "v" + tag.version.String()
		switch {
		case published[name]:
			if !slices.Contains(released, name) {
				released = append(released, name)
			}
		case !resume || unpublished.less(tag.version):
			unpublished, resume = tag.version, true
		}
	}
	sort.Strings(released)
	next := bumpVersion(base, bump)
	if len(released) > 0 {
		resume = false
	} else if resume {
		next = unpublished
	}
	build, err := buildNumber(next)
	if err != nil {
		return releasePlan{}, err
	}
	return releasePlan{next.String(), build, resume, released}, nil
}

// readNames returns the non-empty lines of a file as a set.
func readNames(path string) (map[string]bool, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	names := map[string]bool{}
	for _, line := range splitLines(string(data)) {
		if name := strings.TrimSpace(line); name != "" {
			names[name] = true
		}
	}
	return names, nil
}

type releaseVersionArgs struct {
	bump, head, ref, defaultBranch, published string
	dryRun                                    bool
}

func parseReleaseVersionArgs(args []string, stderr io.Writer) (releaseVersionArgs, error) {
	var a releaseVersionArgs
	flags := newFlags("release-version", stderr)
	flags.StringVar(&a.bump, "bump", "", "patch、minor 或 major（必填）")
	flags.StringVar(&a.head, "head", "", "要发布的提交（必填）")
	flags.StringVar(&a.published, "published", "", "已发布（非草稿）的 GitHub Release 的 tag 名，一行一个（必填）")
	flags.BoolVar(&a.dryRun, "dry-run", false, "只验证：任意分支可跑，头提交已发过版也照常算版本")
	flags.StringVar(&a.ref, "ref", "", "运行所在的 ref，如 refs/heads/master（非 dry-run 必填）")
	flags.StringVar(&a.defaultBranch, "default-branch", "", "默认分支名（非 dry-run 必填）")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		return a, err
	}
	if len(positional) > 0 {
		fmt.Fprintf(stderr, "多余的参数：%v\n", positional)
		return a, errUsage
	}
	required := map[string]string{"head": a.head, "published": a.published}
	if !a.dryRun {
		required["ref"], required["default-branch"] = a.ref, a.defaultBranch
	}
	for _, name := range []string{"head", "published", "ref", "default-branch"} {
		if value, ok := required[name]; ok && value == "" {
			fmt.Fprintf(stderr, "缺少 --%s\n", name)
			return a, errUsage
		}
	}
	return a, requireChoice(stderr, "bump", a.bump, "patch", "minor", "major")
}

func releaseVersionMain(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	a, err := parseReleaseVersionArgs(args, stderr)
	if err != nil {
		return err
	}
	if !a.dryRun && a.ref != "refs/heads/"+a.defaultBranch {
		return fmt.Errorf("正式发版只能在 %s 上运行；其他分支加 -f dry_run=true 只做验证。", a.defaultBranch)
	}
	published, err := readNames(a.published)
	if err != nil {
		return err
	}
	input, err := io.ReadAll(stdin)
	if err != nil {
		return err
	}
	result, err := plan(string(input), a.bump, a.head, published)
	if err != nil {
		return err
	}
	if len(result.released) > 0 && !a.dryRun {
		return errors.New("这个提交已发过版（" + strings.Join(result.released, ", ") + "）；有新提交后再发下一个版本。")
	}
	if result.resume {
		fmt.Fprintf(stderr, "头提交已有 tag v%s，但同名 Release 未发布：沿用这个版本续跑，跳过打 tag。\n", result.version)
	}
	fmt.Fprintf(stdout, "version=%s\nbuild=%d\ntag=v%s\nresume=%t\n", result.version, result.build, result.version, result.resume)
	return nil
}
