package httpapi

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"unicode/utf8"
)

// Reject duplicate object keys so intermediaries and signed callers cannot assign
// different meanings to the same financial request. Limit nesting before decoding.
func validateJSON(data []byte) error {
	if !utf8.Valid(data) {
		return fmt.Errorf("invalid UTF-8")
	}
	d := json.NewDecoder(bytes.NewReader(data))
	d.UseNumber()
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 32 {
			return fmt.Errorf("JSON nesting limit")
		}
		t, e := d.Token()
		if e != nil {
			return e
		}
		delim, ok := t.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for d.More() {
				k, e := d.Token()
				if e != nil {
					return e
				}
				key, ok := k.(string)
				if !ok || seen[key] {
					return fmt.Errorf("duplicate JSON key")
				}
				seen[key] = true
				if e = walk(depth + 1); e != nil {
					return e
				}
			}
		case '[':
			for d.More() {
				if e = walk(depth + 1); e != nil {
					return e
				}
			}
		default:
			return fmt.Errorf("invalid JSON")
		}
		_, e = d.Token()
		return e
	}
	if e := walk(0); e != nil {
		return e
	}
	if _, e := d.Token(); e != io.EOF {
		return fmt.Errorf("multiple JSON values")
	}
	return nil
}
