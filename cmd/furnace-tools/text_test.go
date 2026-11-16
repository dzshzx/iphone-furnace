package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestReadReplacingReplacesEachUndecodableByte(t *testing.T) {
	path := filepath.Join(t.TempDir(), "log")
	for input, want := range map[string]string{
		"炉 ok":              "炉 ok",
		"a\xff\xfeb":        "a��b",
		"\xe2\x82 cut":      "�� cut",
		"\xed\xa0\x80":      "���",
		"kept \xef\xbf\xbd": "kept �",
	} {
		if err := os.WriteFile(path, []byte(input), 0o644); err != nil {
			t.Fatal(err)
		}
		got, err := readReplacing(path)
		if err != nil || got != want {
			t.Errorf("readReplacing(%q) = %q, %v; want %q", input, got, err, want)
		}
	}
}
