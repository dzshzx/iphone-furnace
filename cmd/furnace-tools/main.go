// Command furnace-tools holds the build-time helpers of the Furnace release:
// release version planning, the macOS validation report, the unsigned IPA
// check and the app icon renderer. Standard library only, run with
// `go run ./cmd/furnace-tools <subcommand>` from the repository root.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
)

const usage = `用法：furnace-tools <子命令> [参数]

子命令：
  release-version  从 git ls-remote --tags 的输出算下一个版本号与 build 号
  ci-report        汇总一次 macOS CI 运行，输出 Markdown 验证报告
  verify-ipa       检查未签名 IPA：arm64、iOS 平台、三档模型、Metal 内核、无签名
  generate-icon    生成确定性的 App 图标 PNG
`

// errUsage marks argument errors; main exits 2 for them, like argparse.
var errUsage = errors.New("usage")

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}
	commands := map[string]func([]string, io.Reader, io.Writer, io.Writer) error{
		"release-version": releaseVersionMain,
		"ci-report":       ciReportMain,
		"verify-ipa":      verifyIPAMain,
		"generate-icon":   generateIconMain,
	}
	command, ok := commands[args[0]]
	if !ok {
		fmt.Fprint(stderr, usage)
		return 2
	}
	err := command(args[1:], stdin, stdout, stderr)
	switch {
	case err == nil:
		return 0
	case errors.Is(err, errUsage), errors.Is(err, flag.ErrHelp):
		return 2
	default:
		fmt.Fprintf(stderr, "error: %v\n", err)
		return 1
	}
}

// newFlags returns a flag set whose parse errors are reported to stderr and
// surface as errUsage.
func newFlags(name string, stderr io.Writer) *flag.FlagSet {
	flags := flag.NewFlagSet("furnace-tools "+name, flag.ContinueOnError)
	flags.SetOutput(stderr)
	return flags
}

// parseInterspersed parses flags that may appear before or after positional
// arguments and returns the positional arguments in order.
func parseInterspersed(flags *flag.FlagSet, args []string) ([]string, error) {
	var positional []string
	for {
		if err := flags.Parse(args); err != nil {
			return nil, fmt.Errorf("%w: %v", errUsage, err)
		}
		rest := flags.Args()
		if len(rest) == 0 {
			return positional, nil
		}
		positional = append(positional, rest[0])
		args = rest[1:]
	}
}

// requireChoice reports an argparse-style error when value is not one of choices.
func requireChoice(stderr io.Writer, name, value string, choices ...string) error {
	for _, choice := range choices {
		if value == choice {
			return nil
		}
	}
	fmt.Fprintf(stderr, "--%s: 取值须为 %v，实际为 %q\n", name, choices, value)
	return errUsage
}
