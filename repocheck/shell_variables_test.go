// Package repocheck holds repository-wide checks that run as Go tests.
package repocheck

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// The macOS runner's /bin/bash 3.2 reads a multibyte character right after a
// variable name as part of the name, expands it to nothing and leaves half a
// character behind; a variable followed by Chinese text must be written ${VAR}.
var unbraced = regexp.MustCompile(`\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]`)

func TestShellVariablesBeforeNonASCIITextAreBraced(t *testing.T) {
	var files []string
	for _, pattern := range []string{"../.github/workflows/*.yml", "../scripts/*.sh"} {
		matches, err := filepath.Glob(pattern)
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, matches...)
	}
	if len(files) == 0 {
		t.Fatal("no workflow or shell files found")
	}
	var offenders []string
	for _, path := range files {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		for number, line := range strings.Split(string(data), "\n") {
			if unbraced.MatchString(line) {
				offenders = append(offenders, fmt.Sprintf("%s:%d", strings.TrimPrefix(path, "../"), number+1))
			}
		}
	}
	if len(offenders) > 0 {
		t.Fatalf("unbraced variables before non-ASCII text: %v", offenders)
	}
}
