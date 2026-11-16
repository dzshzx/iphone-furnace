package main

// release-version: release.yml pipes `git ls-remote --tags <repo>` into this
// subcommand and appends its key=value output to $GITHUB_OUTPUT.

import (
	"errors"
	"fmt"
	"io"
	"regexp"
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
	version string
	build   int
	onHead  []string // released pure tags already on head, sorted
}

func plan(lsRemote, bump, head string) (releasePlan, error) {
	tags := pureTags(lsRemote)
	var base version
	for _, tag := range tags {
		if base.less(tag.version) {
			base = tag.version
		}
	}
	next := bumpVersion(base, bump)
	build, err := buildNumber(next)
	if err != nil {
		return releasePlan{}, err
	}
	seen := map[string]bool{}
	onHead := []string{}
	for _, tag := range tags {
		name := "v" + tag.version.String()
		if tag.sha == head && !seen[name] {
			seen[name] = true
			onHead = append(onHead, name)
		}
	}
	sort.Strings(onHead)
	return releasePlan{next.String(), build, onHead}, nil
}

func releaseVersionMain(args []string, stdin io.Reader, stdout, stderr io.Writer) error {
	flags := newFlags("release-version", stderr)
	bump := flags.String("bump", "", "patch、minor 或 major（必填）")
	head := flags.String("head", "", "要发布的提交（必填）")
	requireUnreleased := flags.Bool("require-unreleased", false, "--head 已带纯 vX.Y.Z tag 时失败")
	positional, err := parseInterspersed(flags, args)
	if err != nil {
		return err
	}
	if len(positional) > 0 {
		fmt.Fprintf(stderr, "多余的参数：%v\n", positional)
		return errUsage
	}
	if *head == "" {
		fmt.Fprintln(stderr, "缺少 --head")
		return errUsage
	}
	if err := requireChoice(stderr, "bump", *bump, "patch", "minor", "major"); err != nil {
		return err
	}
	input, err := io.ReadAll(stdin)
	if err != nil {
		return err
	}
	result, err := plan(string(input), *bump, *head)
	if err != nil {
		return err
	}
	if len(result.onHead) > 0 && *requireUnreleased {
		return errors.New("这个提交已发过版（" + strings.Join(result.onHead, ", ") + "）；有新提交后再发下一个版本。")
	}
	fmt.Fprintf(stdout, "version=%s\nbuild=%d\ntag=v%s\n", result.version, result.build, result.version)
	return nil
}
