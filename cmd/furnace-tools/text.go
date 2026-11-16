package main

import (
	"encoding/json"
	"os"
	"strings"
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

// readReplacing reads a file and replaces every undecodable byte with U+FFFD.
func readReplacing(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	if utf8.Valid(data) {
		return string(data), nil
	}
	var b strings.Builder
	for len(data) > 0 {
		r, size := utf8.DecodeRune(data)
		if r == utf8.RuneError && size == 1 {
			b.WriteRune(utf8.RuneError)
		} else {
			b.Write(data[:size])
		}
		data = data[size:]
	}
	return b.String(), nil
}

// pyStr renders a decoded JSON value the way Python's str() renders the
// value json.loads would produce for it.
func pyStr(value any) string {
	switch v := value.(type) {
	case nil:
		return "None"
	case string:
		return v
	case bool:
		if v {
			return "True"
		}
		return "False"
	case json.Number:
		return v.String()
	default:
		data, err := json.Marshal(v)
		if err != nil {
			return "?"
		}
		return string(data)
	}
}

// truthy follows Python truthiness for decoded JSON values.
func truthy(value any) bool {
	switch v := value.(type) {
	case nil:
		return false
	case string:
		return v != ""
	case bool:
		return v
	case json.Number:
		f, err := v.Float64()
		return err != nil || f != 0
	case []any:
		return len(v) > 0
	case map[string]any:
		return len(v) > 0
	}
	return true
}

// get returns object[key] when present (even if null), else fallback, like dict.get.
func get(object map[string]any, key string, fallback any) any {
	if value, ok := object[key]; ok {
		return value
	}
	return fallback
}

// objects keeps the JSON objects of a list value; other values yield nothing.
func objects(value any) []map[string]any {
	list, _ := value.([]any)
	var result []map[string]any
	for _, item := range list {
		if object, ok := item.(map[string]any); ok {
			result = append(result, object)
		}
	}
	return result
}
