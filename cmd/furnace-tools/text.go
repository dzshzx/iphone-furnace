package main

import (
	"os"
	"unicode/utf8"
)

// lineBreaks are the separators that Python's str.splitlines() honours.
func isLineBreak(r rune) bool {
	switch r {
	case '\n', '\r', '\v', '\f', 0x1c, 0x1d, 0x1e, 0x85, 0x2028, 0x2029:
		return true
	}
	return false
}

// splitLines splits text like Python's str.splitlines(): every line break
// ends a line, "\r\n" counts once, and a trailing break adds no empty line.
func splitLines(text string) []string {
	var lines []string
	start := 0
	for i := 0; i < len(text); {
		r, size := utf8.DecodeRuneInString(text[i:])
		if !isLineBreak(r) {
			i += size
			continue
		}
		lines = append(lines, text[start:i])
		i += size
		if r == '\r' && i < len(text) && text[i] == '\n' {
			i++
		}
		start = i
	}
	if start < len(text) {
		lines = append(lines, text[start:])
	}
	return lines
}

// readReplacing reads a file and replaces every undecodable byte with U+FFFD
// (one per byte, unlike strings.ToValidUTF8, which collapses a run into one).
func readReplacing(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string([]rune(string(data))), nil
}
